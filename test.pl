#!/usr/bin/perl

use v5.26;
require '/mnt/c/Github/File-Find/Find_linux_nosymlink.pm';

File::Find::_find_opt({ wanted => sub {say $_} }, '.');
