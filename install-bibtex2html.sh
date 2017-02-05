#!/bin/sh
set -e
wget --no-check-certificate http://www.lri.fr/~filliatr/ftp/bibtex2html/bibtex2html-1.98.tar.gz
tar -xzvf bibtex2html-1.98.tar.gz
cd bibtex2html-1.98 && ./configure --prefix=$HOME/bibtex2html && make && make install
export PATH=$PATH:$HOME/bibtex2html:$HOME/bibtex2html/bin