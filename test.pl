#!/usr/bin/perl

use v5.26;
require '/mnt/c/Github/File-Find/Find_linux_nosymlink.pm';

File::Find::find({ wanted => sub {say $_} }, '.');
