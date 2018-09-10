utils/hello_USES_CABAL = YES
utils/hello_PACKAGE = hello
utils/hello_dist-install_INSTALL = YES
utils/hello_dist-install_INSTALL_INPLACE = YES
utils/hello_dist-install_PROGNAME = hello
utils/hello_dist-install_SHELL_WRAPPER = YES
utils/hello_dist-install_INSTALL_SHELL_WRAPPER_NAME = hello

$(eval $(call build-prog,utils/hello,dist-install,1))
