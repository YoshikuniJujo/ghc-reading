utils/checkCmmParsed_USES_CABAL = YES
utils/checkCmmParsed_PACKAGE = checkCmmParsed
utils/checkCmmParsed_dist-install_INSTALL = YES
utils/checkCmmParsed_dist-install_INSTALL_INPLACE = YES
utils/checkCmmParsed_dist-install_PROGNAME = checkCmmParsed
utils/checkCmmParsed_dist-install_SHELL_WRAPPER = YES
utils/checkCmmParsed_dist-install_INSTALL_SHELL_WRAPPER_NAME = checkCmmParsed

$(eval $(call build-prog,utils/checkCmmParsed,dist-install,1))
