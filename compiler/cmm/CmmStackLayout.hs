module CmmStackLayout
    ( SlotEnv, liveSlotAnal, liveSlotTransfers, removeLiveSlotDefs
    , layout, manifestSP, igraph, areaBuilder
    , stubSlotsOnDeath ) -- to help crash early during debugging
where

import Constants
import qualified Prelude as P
import Prelude hiding (zip, unzip, last)

import BlockId
import CmmExpr
import CmmProcPointZ
import CmmTx
import DFMonad
import FiniteMap
import Maybes
import MkZipCfg
import MkZipCfgCmm hiding (CmmBlock, CmmGraph)
import Monad
import Outputable
import Panic
import ZipCfg
import ZipCfgCmmRep
import ZipDataflow

------------------------------------------------------------------------
--                    Stack Layout                                    --
------------------------------------------------------------------------

-- | Before we lay out the stack, we need to know something about the
-- liveness of the stack slots. In particular, to decide whether we can
-- reuse a stack location to hold multiple stack slots, we need to know
-- when each of the stack slots is used.
-- Although tempted to use something simpler, we really need a full interference
-- graph. Consider the following case:
--   case <...> of
--     1 -> <spill x>; // y is dead out
--     2 -> <spill y>; // x is dead out
--     3 -> <spill x and y>
-- If we consider the arms in order and we use just the deadness information given by a
-- dataflow analysis, we might decide to allocate the stack slots for x and y
-- to the same stack location, which will lead to incorrect code in the third arm.
-- We won't make this mistake with an interference graph.

-- First, the liveness analysis.
-- We represent a slot with an area, an offset into the area, and a width.
-- Tracking the live slots is a bit tricky because there may be loads and stores
-- into only a part of a stack slot (e.g. loading the low word of a 2-word long),
-- e.g. Slot A 0 8 overlaps with Slot A 4 4.
--
-- The definition of a slot set is intended to reduce the number of overlap
-- checks we have to make. There's no reason to check for overlap between
-- slots in different areas, so we segregate the map by Area's.
-- We expect few slots in each Area, so we collect them in an unordered list.
-- To keep these lists short, any contiguous live slots are coalesced into
-- a single slot, on insertion.

slotLattice :: DataflowLattice SubAreaSet
slotLattice = DataflowLattice "live slots" emptyFM add True
  where add new old = case foldFM addArea (False, old) new of
                        (True,  x) -> aTx  x
                        (False, x) -> noTx x
        addArea a newSlots z = foldr (addSlot a) z newSlots
        addSlot a slot (changed, map) =
          let (c, live) = liveGen slot $ lookupWithDefaultFM map [] a
          in (c || changed, addToFM map a live)

type SlotEnv   = BlockEnv SubAreaSet
type SlotFix a = FuelMonad (BackwardFixedPoint Middle Last SubAreaSet a)

liveSlotAnal :: LGraph Middle Last -> FuelMonad SlotEnv
liveSlotAnal g = liftM zdfFpFacts (res :: SlotFix ())
  where res = zdfSolveFromL emptyBlockEnv "live slot analysis" slotLattice
                            liveSlotTransfers (fact_bot slotLattice) g

-- Add the subarea s to the subareas in the list-set (possibly coalescing it with
-- adjacent subareas), and also return whether s was a new addition.
liveGen :: SubArea -> [SubArea] -> (Bool, [SubArea])
liveGen s set = liveGen' s set []
  where liveGen' s [] z = (True, s : z)
        liveGen' s@(a, hi, w) (s'@(a', hi', w') : rst) z =
          if a /= a' || hi < lo' || lo > hi' then    -- no overlap
            liveGen' s rst (s' : z)
          else if s' `contains` s then               -- old contains new
            (False, set)
          else                                       -- overlap: coalesce the slots
            let new_hi = max hi hi'
                new_lo = min lo lo'
            in liveGen' (a, new_hi, new_hi - new_lo) rst z
          where lo  = hi  - w  -- remember: areas grow down
                lo' = hi' - w'
        contains (a, hi, w) (a', hi', w') =
          a == a' && hi >= hi' && hi - w <= hi' - w'

liveKill :: SubArea -> [SubArea] -> [SubArea]
liveKill (a, hi, w) set = pprTrace "killing slots in area" (ppr a) $ liveKill' set []
  where liveKill' [] z = z
        liveKill' (s'@(a', hi', w') : rst) z =
          if a /= a' || hi < lo' || lo > hi' then    -- no overlap
            liveKill' rst (s' : z)
          else                                       -- overlap: split the old slot
            let z'  = if hi' > hi  then (a, hi', hi' - hi)  : z else z
                z'' = if lo  > lo' then (a, lo,  lo  - lo') : z' else z'
            in liveKill' rst z''
          where lo  = hi  - w  -- remember: areas grow down
                lo' = hi' - w'

-- Note: the stack slots that hold variables returned on the stack are not
-- considered live in to the block -- we treat the first node as a definition site.
-- BEWARE?: Am I being a little careless here in failing to check for the
-- entry Id (which would use the CallArea Old).
liveSlotTransfers :: BackwardTransfers Middle Last SubAreaSet
liveSlotTransfers =
  BackwardTransfers first liveInSlots liveLastIn
    where first live id = delFromFM live (CallArea (Young id))

-- Slot sets: adding slots, removing slots, and checking for membership.
liftToArea :: Area -> ([SubArea] -> [SubArea]) -> SubAreaSet -> SubAreaSet 
addSlot, removeSlot :: SubAreaSet -> SubArea -> SubAreaSet
elemSlot            :: SubAreaSet -> SubArea -> Bool
liftToArea a f map = addToFM map a $ f (lookupWithDefaultFM map [] a)
addSlot    live (a, i, w) = liftToArea a (snd . liveGen  (a, i, w)) live
removeSlot live (a, i, w) = liftToArea a       (liveKill (a, i, w)) live
elemSlot   live (a, i, w) =
  not $ fst $ liveGen  (a, i, w) (lookupWithDefaultFM live [] a)

removeLiveSlotDefs :: (DefinerOfSlots s, UserOfSlots s) => SubAreaSet -> s -> SubAreaSet
removeLiveSlotDefs = foldSlotsDefd removeSlot

liveInSlots :: (DefinerOfSlots s, UserOfSlots s) => SubAreaSet -> s -> SubAreaSet
liveInSlots live x = foldSlotsUsed addSlot (removeLiveSlotDefs live x) x

liveLastIn :: (BlockId -> SubAreaSet) -> Last -> SubAreaSet
liveLastIn env l = liveInSlots (liveLastOut env l) l

-- Don't forget to keep the outgoing parameters in the CallArea live,
-- as well as the update frame.
-- Note: We have to keep the update frame live at a call because of the
-- case where the function doesn't return -- in that case, there won't
-- be a return to keep the update frame live. We'd still better keep the
-- info pointer in the update frame live at any call site;
-- otherwise we could screw up the garbage collector.
liveLastOut :: (BlockId -> SubAreaSet) -> Last -> SubAreaSet
liveLastOut env l =
  case l of
    LastCall _ Nothing n _ -> 
      add_area (CallArea Old) n out -- add outgoing args (includes upd frame)
    LastCall _ (Just k) n (Just upd_n) ->
      add_area (CallArea Old) n (add_area (CallArea (Young k)) n out)
    LastCall _ (Just k) n Nothing ->
      add_area (CallArea (Young k)) n out
    _ -> out
  where out = joinOuts slotLattice env l
        add_area _ n live | n == 0 = live
        add_area a n live =
          addToFM live a $ snd $ liveGen (a, n, n) $ lookupWithDefaultFM live [] a

-- The liveness analysis must be precise: otherwise, we won't know if a definition
-- should really kill a live-out stack slot.
-- But the interference graph does not have to be precise -- it might decide that
-- any live areas interfere. To maintain both a precise analysis and an imprecise
-- interference graph, we need to convert the live-out stack slots to graph nodes
-- at each and every instruction; rather than reconstruct a new list of nodes
-- every time, I provide a function to fold over the nodes, which should be a
-- reasonably efficient approach for the implementations we envision.
-- Of course, it will probably be much easier to program if we just return a list...
type Set x = FiniteMap x ()
data IGraphBuilder n =
  Builder { foldNodes     :: forall z. SubArea -> (n -> z -> z) -> z -> z
          , _wordsOccupied :: AreaMap -> AreaMap -> n -> [Int]
          }

areaBuilder :: IGraphBuilder Area
areaBuilder = Builder fold words
  where fold (a, _, _) f z = f a z
        words areaSize areaMap a =
          case lookupFM areaMap a of
            Just addr -> [addr .. addr + (lookupFM areaSize a `orElse`
                                          pprPanic "wordsOccupied: unknown area" (ppr a))]
            Nothing   -> []

--slotBuilder :: IGraphBuilder (Area, Int)
--slotBuilder = undefined

-- Now, we can build the interference graph.
-- The usual story: a definition interferes with all live outs and all other
-- definitions.
type IGraph x = FiniteMap x (Set x)
type IGPair x = (IGraph x, IGraphBuilder x)
igraph :: (Ord x) => IGraphBuilder x -> SlotEnv -> LGraph Middle Last -> IGraph x
igraph builder env g = foldr interfere emptyFM (postorder_dfs g)
  where foldN = foldNodes builder
        interfere block igraph =
          let (h, l) = goto_end (unzip block)
              --heads :: ZHead Middle -> (IGraph x, SubAreaSet) -> IGraph x
              heads (ZFirst _ _) (igraph, _)       = igraph
              heads (ZHead h m)    (igraph, liveOut) =
                heads h (addEdges igraph m liveOut, liveInSlots liveOut m)
              -- add edges between a def and the other defs and liveouts
              addEdges igraph i out = fst $ foldSlotsDefd addDef (igraph, out) i
              addDef (igraph, out) def@(a, _, _) =
                (foldN def (addDefN out) igraph,
                 addToFM out a (snd $ liveGen def (lookupWithDefaultFM out [] a)))
              addDefN out n igraph =
                let addEdgeNO o igraph = foldN o addEdgeNN igraph
                    addEdgeNN n' igraph = addEdgeNN' n n' $ addEdgeNN' n' n igraph
                    addEdgeNN' n n' igraph = addToFM igraph n (addToFM set n' ())
                      where set = lookupWithDefaultFM igraph emptyFM n
                in foldFM (\ _ os igraph -> foldr addEdgeNO igraph os) igraph out
              env' bid = lookupBlockEnv env bid `orElse` panic "unknown blockId in igraph"
          in heads h $ case l of LastExit    -> (igraph, emptyFM)
                                 LastOther l -> (addEdges igraph l $ liveLastOut env' l,
                                                 liveLastIn env' l)

-- Before allocating stack slots, we need to collect one more piece of information:
-- what's the highest offset (in bytes) used in each Area?
-- We'll need to allocate that much space for each Area.
getAreaSize :: LGraph Middle Last -> AreaMap
getAreaSize g@(LGraph _ off _) =
  fold_blocks (fold_fwd_block first add_regslots last)
              (unitFM (CallArea Old) off) g
  where first id (StackInfo {argBytes = Just off}) z = add z (CallArea (Young id)) off
        first _  _          z = z
        add_regslots i z = foldSlotsUsed addSlot (foldSlotsDefd addSlot z i) i
        last l@(LastOther (LastCall _ Nothing off _)) z =
          add_regslots l (add z (CallArea Old) off)
        last l@(LastOther (LastCall _ (Just k) off _)) z =
          add_regslots l (add z (CallArea (Young k)) off)
        last l z = add_regslots l z
        addSlot z (a@(RegSlot _), off, _) = add z a off
        addSlot z _ = z
        add z a off = addToFM z a (max off (lookupWithDefaultFM z 0 a))


-- Find the Stack slots occupied by the subarea's conflicts
conflictSlots :: Ord x => IGPair x -> AreaMap -> AreaMap -> SubArea -> Set Int
conflictSlots (ig, Builder foldNodes wordsOccupied) areaSize areaMap subarea =
  foldNodes subarea foldNode emptyFM
  where foldNode n set = foldFM conflict set $ lookupWithDefaultFM ig emptyFM n
        conflict n' () set = liveInSlots areaMap n' set
        -- Add stack slots occupied by igraph node n
        liveInSlots areaMap n set = foldr setAdd set (wordsOccupied areaSize areaMap n)
        setAdd w s = addToFM s w ()

-- Find any open space on the stack, starting from the offset.
-- If the area is a CallArea or a spill slot for a pointer, then it must
-- be word-aligned.
freeSlotFrom :: Ord x => IGPair x -> AreaMap -> Int -> AreaMap -> Area -> Int
freeSlotFrom ig areaSize offset areaMap area =
  let size = lookupFM areaSize area `orElse` 0
      conflicts = conflictSlots ig areaSize areaMap (area, size, size)
      -- CallAreas and Ptrs need to be word-aligned (round up!)
      align = case area of CallArea _                                -> align'
                           RegSlot  r | isGcPtrType (localRegType r) -> align'
                           RegSlot  _                                -> id
      align' n = (n + (wORD_SIZE - 1)) `div` wORD_SIZE * wORD_SIZE
      -- Find a space big enough to hold the area
      findSpace curr 0 = curr
      findSpace curr cnt = -- part of target slot, # of bytes left to check
        if elemFM curr conflicts then
          findSpace (align (curr + size)) size -- try the next (possibly) open space
        else findSpace (curr - 1) (cnt - 1)
  in findSpace (align (offset + size)) size

-- Find an open space on the stack, and assign it to the area.
allocSlotFrom :: Ord x => IGPair x -> AreaMap -> Int -> AreaMap -> Area -> AreaMap
allocSlotFrom ig areaSize from areaMap area =
  if elemFM area areaMap then areaMap
  else addToFM areaMap area $ freeSlotFrom ig areaSize from areaMap area

-- | Greedy stack layout.
-- Compute liveness, build the interference graph, and allocate slots for the areas.
-- We visit each basic block in a (generally) forward order.
-- At each instruction that names a register subarea r, we immediately allocate
-- any available slot on the stack by the following procedure:
--  1. Find the nodes N' that conflict with r
--  2. Find the stack slots used for N'
--  3. Choose a contiguous stack space s not in N' (s must be large enough to hold r)
-- For a CallArea, we allocate the stack space only when we reach a function
-- call that returns to the CallArea's blockId.
-- We use a similar procedure, with one exception: the stack space
-- must be allocated below the youngest stack slot that is live out.

-- Note: The stack pointer only has to be younger than the youngest live stack slot
-- at proc points. Otherwise, the stack pointer can point anywhere.
layout :: ProcPointSet -> SlotEnv -> LGraph Middle Last -> AreaMap
layout procPoints env g@(LGraph _ entrySp _) =
  let builder = areaBuilder
      ig = (igraph builder env g, builder)
      env' bid = lookupBlockEnv env bid `orElse` panic "unknown blockId in igraph"
      areaSize = getAreaSize g
      -- Find the slots that are live-in to the block
      live_in (ZTail m l) = liveInSlots (live_in l) m
      live_in (ZLast (LastOther l)) = liveLastIn env' l
      live_in (ZLast LastExit) = emptyFM 
      -- Find the youngest live stack slot
      youngest_live areaMap live = fold_subareas young_slot live 0
        where young_slot (a, o, _) z = case lookupFM areaMap a of
                                         Just top -> max z $ top + o
                                         Nothing  -> z
      fold_subareas :: (SubArea -> z -> z) -> SubAreaSet -> z -> z
      fold_subareas f m z = foldFM (\_ s z -> foldr f z s) z m
      -- Allocate space for spill slots and call areas
      allocVarSlot = allocSlotFrom ig areaSize 0
      allocCallSlot areaMap (Block id stackInfo t)
        | elemBlockSet id procPoints =
        let young  = youngest_live areaMap $ live_in t
            start = case returnOff stackInfo of Just b  -> max b young
                                                Nothing -> young
            z = allocSlotFrom ig areaSize start areaMap (CallArea (Young id))
        in pprTrace "allocCallSlot for" (ppr id <+> ppr young <+> ppr (live_in t) <+> ppr z) z
      allocCallSlot areaMap _ = areaMap
      -- mid foreign calls need to have info tables placed on the stack
      allocMidCall m@(MidForeignCall (Safe bid _) _ _ _) t areaMap =
        let young     = youngest_live areaMap $ removeLiveSlotDefs (live_in t) m
            area      = CallArea (Young bid)
            areaSize' = addToFM areaSize area (widthInBytes (typeWidth gcWord))
        in  allocSlotFrom ig areaSize' young areaMap area
      allocMidCall _ _ areaMap = areaMap
      alloc m t areaMap =
          foldSlotsDefd alloc' (foldSlotsUsed alloc' (allocMidCall m t areaMap) m) m
        where alloc' areaMap (a@(RegSlot _), _, _) = allocVarSlot areaMap a
              alloc' areaMap _ = areaMap
      layoutAreas areaMap b@(Block _ _ t) = layout areaMap t
        where layout areaMap (ZTail m t) = layout (alloc m t areaMap) t
              layout areaMap (ZLast _)   = allocCallSlot areaMap b
      areaMap = foldl layoutAreas (addToFM emptyFM (CallArea Old) 0) (postorder_dfs g)
  in pprTrace "ProcPoints" (ppr procPoints) $
       pprTrace "Area SizeMap" (ppr areaSize) $
         pprTrace "Entry SP" (ppr entrySp) $
           pprTrace "Area Map" (ppr areaMap) $ areaMap

-- After determining the stack layout, we can:
-- 1. Replace references to stack Areas with addresses relative to the stack
--    pointer.
-- 2. Insert adjustments to the stack pointer to ensure that it is at a
--    conventional location at each proc point.
--    Because we don't take interrupts on the execution stack, we only need the
--    stack pointer to be younger than the live values on the stack at proc points.
-- 3. Compute the maximum stack offset used in the procedure and replace
--    the stack high-water mark with that offset.
manifestSP :: ProcPointSet -> BlockEnv Status -> AreaMap ->
                LGraph Middle Last -> FuelMonad (LGraph Middle Last)
manifestSP procPoints procMap areaMap g@(LGraph entry args blocks) =
  liftM (LGraph entry args) blocks'
  where blocks' = foldl replB (return emptyBlockEnv) (postorder_dfs g)
        slot a = pprTrace "slot" (ppr a) $
                   lookupFM areaMap a `orElse` panic "unallocated Area"
        slot' (Just id) = slot $ CallArea (Young id)
        slot' Nothing   = slot $ CallArea Old
        sp_high = maxSlot slot g
        proc_entry_sp = slot (CallArea Old) + args
        sp_on_entry id | id == entry = proc_entry_sp
        sp_on_entry id =
          case lookupBlockEnv blocks id of
            Just (Block _ (StackInfo {argBytes = Just o}) _) -> slot' (Just id) + o
            _ -> 
             case expectJust "sp_on_entry" (lookupBlockEnv procMap id) of
               ReachedBy pp ->
                 case blockSetToList pp of
                   [id] -> sp_on_entry id
                   _    -> panic "block not reached by one proc point"
               ProcPoint -> pprPanic "procpoint doesn't take any arguments?"
                               (ppr id <+> ppr g <+> ppr procPoints <+> ppr procMap)

        -- On entry to procpoints, the stack pointer is conventional;
        -- otherwise, we check the SP set by predecessors.
        replB :: FuelMonad (BlockEnv CmmBlock) -> CmmBlock -> FuelMonad (BlockEnv CmmBlock)
        replB blocks (Block id o t) =
          do bs <- replTail (Block id o) spIn t
             pprTrace "spIn" (ppr id <+> ppr spIn)$
              liftM (flip (foldr insertBlock) bs) blocks
          where spIn = sp_on_entry id
        replTail :: (ZTail Middle Last -> CmmBlock) -> Int -> (ZTail Middle Last) -> 
                    FuelMonad ([CmmBlock])
        replTail h spOff (ZTail m@(MidForeignCall (Safe bid _) _ _ _) t) =
          replTail (\t' -> h (setSp spOff spOff' (ZTail (middle spOff m) t'))) spOff' t
            where spOff' = slot' (Just bid) + widthInBytes (typeWidth gcWord)
        replTail h spOff (ZTail m t) = replTail (h . ZTail (middle spOff m)) spOff t
        replTail h spOff (ZLast (LastOther l)) = fixSp h spOff l
        replTail h _   l@(ZLast LastExit) = return [h l]
        middle spOff m = mapExpDeepMiddle (replSlot spOff) m
        last   spOff l = mapExpDeepLast   (replSlot spOff) l
        replSlot spOff (CmmStackSlot a i) = CmmRegOff (CmmGlobal Sp) (spOff - (slot a + i))
        replSlot spOff (CmmLit CmmHighStackMark) = -- replacing the high water mark
          CmmLit (CmmInt (toInteger (max 0 (sp_high - proc_entry_sp))) (typeWidth bWord))
        replSlot _ e = e
        -- The block must establish the SP expected at each successsor.
        fixSp :: (ZTail Middle Last -> CmmBlock) -> Int -> Last -> FuelMonad ([CmmBlock])
        fixSp h spOff l@(LastCall _ k n _) = updSp h spOff (slot' k + n) l
        fixSp h spOff l@(LastBranch k) =
          let succSp = sp_on_entry k in
          if succSp /= spOff then
               pprTrace "updSp" (ppr k <> ppr spOff <> ppr (sp_on_entry k)) $
               updSp h spOff succSp l
          else return $ [h (ZLast (LastOther (last spOff l)))]
        fixSp h spOff l = liftM (uncurry (:)) $ fold_succs succ l $ return (b, [])
          where b = h (ZLast (LastOther (last spOff l)))
                succ succId z =
                  let succSp = sp_on_entry succId in
                  if succSp /= spOff then
                    do (b,  bs)  <- z
                       (b', bs') <- insertBetween b [setSpMid spOff succSp] succId
                       return (b', bs ++ bs')
                  else z
        updSp h old new l = return [h $ setSp old new $ ZLast $ LastOther (last new l)]
        setSpMid sp sp' = MidAssign (CmmGlobal Sp) e
          where e = CmmMachOp (MO_Add wordWidth) [CmmReg (CmmGlobal Sp), off]
                off = CmmLit $ CmmInt (toInteger $ sp - sp') wordWidth
        setSp sp sp' t = if sp == sp' then t else ZTail (setSpMid sp sp') t


-- To compute the stack high-water mark, we fold over the graph and
-- compute the highest slot offset.
maxSlot :: (Area -> Int) -> CmmGraph -> Int
maxSlot slotOff g = fold_blocks (fold_fwd_block (\ _ _ x -> x) highSlot highSlot) 0 g
  where highSlot i z = foldSlotsUsed add (foldSlotsDefd add z i) i
        add z (a, i, w) = max z (slotOff a + i)

-----------------------------------------------------------------------------
-- | Sanity check: stub pointers immediately after they die
-----------------------------------------------------------------------------
-- This will miss stack slots that are last used in a Last node,
-- but it should do pretty well...

type StubPtrFix = FuelMonad (BackwardFixedPoint Middle Last SubAreaSet CmmGraph)

stubSlotsOnDeath :: (LGraph Middle Last) -> FuelMonad (LGraph Middle Last)
stubSlotsOnDeath g = liftM zdfFpContents $ (res :: StubPtrFix)
    where res = zdfBRewriteFromL RewriteShallow emptyBlockEnv "stub ptrs" slotLattice
                                 liveSlotTransfers rewrites (fact_bot slotLattice) g
          rewrites = BackwardRewrites first middle last Nothing
          first _ _ = Nothing
          last  _ _ = Nothing
          middle liveSlots m = foldSlotsUsed (stub liveSlots m) Nothing m
          stub liveSlots m rst subarea@(a, off, w) =
            if elemSlot liveSlots subarea then rst
            else let store = mkStore (CmmStackSlot a off)
                                     (stackStubExpr (widthFromBytes w))
                 in case rst of Nothing -> Just (mkMiddle m <*> store)
                                Just g  -> Just (g <*> store)
