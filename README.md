# TeX Live packaging stuff for MacPorts

This repository includes some of the scripts and source files that are used
to build the packages and portfiles for MacPorts's texlive ports.

It is neither very complete nor well documented at the moment.

Contents:
 - `packaging`: the perl script that generates the distfiles and portfiles
   for texmf ports
 - `packaging/portfileinclude`: additional code to be added to individual
   generated portfiles
 - `texlive-common`: source files for the texlive-common package
   (configuration files, etc)
