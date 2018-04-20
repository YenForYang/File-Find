#!/usr/bin/perl

use strict;

require '/mnt/c/Github/File-Find/Find_linux_nosymlink.pm';

File::Find::_find_opt({ wanted => sub {print $_} }, '.');
