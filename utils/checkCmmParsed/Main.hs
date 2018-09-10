import DynFlags
import Outputable
import SysTools
import SysTools.BaseDir
import CmmParse

main :: IO ()
main = do
	top_dir <- findTopDir $ Just "inplace/lib"
	mySettings <- initSysTools top_dir
	myLlvmConfig <- initLlvmConfig top_dir
	dflags <- initDynFlags (defaultDynFlags mySettings myLlvmConfig)
	(_, Just cmm) <- parseCmmFile dflags "samples/cmm/sample.cmm"
	output dflags cmm

output :: Outputable a => DynFlags -> a -> IO ()
output df = putStrLn . showSDoc df . ppr

--	lgraphOfAGraph :: CmmAGraphScoped -> UniqSM CmmGraph
--	lgraphOfAGraph g = do
--		u <- getUniqueM
--		return (labelAGraph (mkBlockId u) g)
--
--	runUniqSM :: UniqSM a -> IO a
--	runUniqSM m = do
--		us <- mkSplitUniqSupply 'u'
--		return (initUs_ us m)
--

--	getMyBlockId :: IO BlockId
--	getMyBlockId = runUniqSM $ do
--		u <- getUniqueM
--		return $ mkBlockId u
