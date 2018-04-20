package File::Find;
use 5.006;
use strict;

our @ISA = qw(Exporter);

use strict;

# Should ideally be my() not our() but local() currently
# refuses to operate on lexicals

our (
	%SLnkSeen, %skipit,

	$wanted_cb, $bydepth, $no_chdir,
	$follow_skip, $full_check,
	$pre_process, $post_process, $dangling_symlinks,

	$dir, $name, $fullname, $prune, $wanted,
);
%skipit = ('.',1,'..',1);
sub _find_dir($$$);

# ASSUME NO TAINT #

sub _find_opt {
	$wanted = shift;
	die 'invalid top dir' unless $_[0];

	# This function must local()ize everything because callbacks may
	# call us again

	local (%SLnkSeen,
		$wanted_callback, $avoid_nlink, $bydepth, $no_chdir,
        $follow_skip, $pre_process, $post_process, $dangling_symlinks,
		$dir, $name, $fullname, $prune);
    local *_ = \my $a;

	### modified version of ryfastcwd_linux() (not very "safe")###
	my($odev, $oino, $cdev, $cino, $tdev, $tino, $cwd);
	($cdev,$cino) = stat '.';
	while (
		($odev, $oino) = ($cdev, $cino),
		chdir '..',
		($cdev, $cino) = stat '.',
		$oino != $cino || $odev != $cdev
	) {
		opendir DIRHANDLEfcwd, '.' or die $!;
		while (readdir DIRHANDLEfcwd) {
			next if $_ eq '.' || $_ eq '..';
			($tdev, $tino) = lstat;
			$tino == $oino && $tdev == $odev
				and substr($cwd, 0, 0, '/'.$_) || closedir DIRHANDLEfcwd;
		}
	}
	chdir $cwd;
	###

	$wanted_cb			= $wanted->{wanted};
	$bydepth			= $wanted->{bydepth};
	$pre_process		= $wanted->{preprocess};
	$post_process		= $wanted->{postprocess};
	$no_chdir			= $wanted->{no_chdir};
	$follow_skip		= $wanted->{follow_skip};
	$dangling_symlinks	= $wanted->{dangling_symlinks};

	# for compatibility reasons (find.pl, find2perl)
	local our ($topdir, $topdev, $topino, $topmode, $topnlink);

	# a symbolic link to a directory doesn't increase the link count
	# avoid_nlink and dont_use_nlink will be always false!

	my ($abs_dir, $Is_Dir);

	Proc_Top_Item:
	for my $TOP (@_) {

		($topdev,$topino,$topmode,$topnlink) = lstat $TOP;

		length $TOP > 1
			and substr($TOP, -1) eq '/' && chop;

		$topnlink //
			warn 'Cant stat ',$TOP,': ',$! and next Proc_Top_Item;
		if (-d _) {
			_find_dir($wanted, $TOP, $topnlink);
		} else {
			$abs_dir = $TOP;

			substr($TOP,-1) ne '/' && $TOP
				and	(	$_ = '' and $dir = $TOP	)
				or	(	$dir = substr($_=$TOP, 0, rindex($TOP, '/')+1, '') || './'	and $abs_dir = $dir	);

			$no_chdir || chdir $abs_dir
				or warn 'Couldnt chdir ',$abs_dir,': ',$! and next Proc_Top_Item;

			$name = $abs_dir . $_;
			$_ = $name if $no_chdir;

			$wanted_cb->(); # REMOVED PROTECTION (curly brackets) against wild "next"!!!
		}

		die 'Cant cd to ',$cwd,': ',$! unless $no_chdir || chdir $cwd;
	}
}

# API:
#  $wanted
#  $p_dir :  "parent directory"
#  $nlink :  what came back from the stat
# preconditions:
#  chdir (if not no_chdir) to dir

sub _find_dir($$$) {
	my ($wanted, $p_dir, $nlink) = @_;
	my (
		$CdLvl,$Level,
		@Stack,@filenames,
		$subcount,$sub_nlink,
		$dir_pref,
		$no_nlink,
		$SE,$dir_name,$dir_rel,
	);
	$SE			= [];
	$dir_name	= $p_dir;
	$dir_rel	= '.';

	$dir_pref	= $p_dir eq '/' ? '/' : $p_dir.'/';

	local ($dir, $name, $prune, *DIR);

		chdir $p_dir or warn 'Cant cd to ',$p_dir,': ',$! and return
	unless $no_chdir || $p_dir eq '.';

	# push the starting directory
	push @Stack, [$CdLvl,$p_dir,$dir_rel,-1] if $bydepth;

	while (defined $SE) {
		unless ($bydepth) {
			$dir	= $p_dir;	# $File::Find::dir
			$name	= $dir_name;# $File::Find::name
			$_		= $no_chdir ? $dir_name : $dir_rel; # $_
			# prune may happen here
			$prune = 0;
			$wanted_cb->();	# NO PROTECTION AGAINST wild "next"
			next if $prune;
		}

		# change to that directory

		(
			chdir $dir_rel or
				warn "Can't cd to (", $p_dir ne '/' ? $p_dir : '', '/) ',$dir_rel,': ',$! and next
		)
		&& ++$CdLvl unless $no_chdir || $dir_rel eq '.';


		$dir = $dir_name; # $File::Find::dir

		# Get the list of files in the current directory.
		opendir DIR, $no_chdir ? $dir_name : '.' or warn 'Cant opendir(',$dir_name,'): ',$! and next;

		@filenames = readdir DIR;
		closedir DIR;
		@filenames = $pre_process->(@filenames)	if $pre_process;
		push @Stack, [$CdLvl,$dir_name,'',-2]	if $post_process;

		# if dir has wrong nlink count, force switch to slower stat method
		++$no_nlink if $nlink < 2;

		if ($nlink == 2 && !$no_nlink) {
			# This dir has no subdirectories.
			for my $FN (@filenames) {
				next if $skipit{$FN};
				$name = $dir_pref . $FN; # $File::Find::name
				$_ = $no_chdir ? $name : $FN; # $_
				$wanted_cb->();
			}
		} else {
			# This dir has subdirectories.
			$subcount = $nlink - 2;

			# HACK: insert directories at this position, so as to preserve
			# the user pre-processed ordering of files (thus ensuring
			# directory traversal is in user sorted order, not at random).
			my $stack_top = @Stack;

			for my $FN (@filenames) {
				next if $skipit{$FN};
				if ($subcount > 0 || $no_nlink) {
					# Seen all the subdirs?
					# check for directoriness.
					# stat is faster for a file in the current directory
					(undef,undef,undef,$sub_nlink) = lstat($no_chdir ? $dir_pref . $FN : $FN);

					if (-d _) {
						--$subcount;
						# HACK: replace push to preserve dir traversal order
						splice @Stack, $stack_top, 0,
								[$CdLvl,$dir_name,$FN,$sub_nlink];
					} else {
						$name = $dir_pref . $FN; # $File::Find::name
						$_ = $no_chdir ? $name : $FN; # $_
						$wanted_cb->();
					}
				} else {
					$name = $dir_pref . $FN; # $File::Find::name
					$_= $no_chdir ? $name : $FN; # $_
					$wanted_cb->();
				}
			}
		}
	} continue {
		while ( defined ($SE = pop @Stack) ) {
			($Level, $p_dir, $dir_rel, $nlink) = @$SE;

				chdir( my $tmp = join '/', ('..') x ($CdLvl-$Level) )
					|| die 'Cant cd to ', $tmp, ' from ', $dir_name,': ',$!
					and $CdLvl = $Level
			if $CdLvl > $Level && !$no_chdir;

			$dir_pref = ( $dir_name = $p_dir eq '/' ? '/'.$dir_rel : $p_dir.'/'.$dir_rel ) . '/';

			if ( $nlink == -2 ) {
				$name = $dir = $p_dir; # $File::Find::name / dir
				$_ = '.';
				$post_process->();           # End-of-directory processing
			} elsif ( $nlink < 0 ) {  # must be finddepth, report dirname now
				$name = $dir_name;
				substr($name, length $name == 2 ? -1 : -2) = '' if substr($name,-2) eq '/.';

				$dir = $p_dir;
				$_ = $no_chdir ? $dir_name : $dir_rel;
				substr($_, length($_) == 2 ? -1 : -2) = '' if substr($_,-2) eq '/.';

				$wanted_callback->();
			} else {
				push @Stack, [$CdLvl,$p_dir,$dir_rel,-1] if $bydepth;
				last;
			}
		}
	}
}

# default
#$File::Find::skip_pattern    = qr/^\.{1,2}\z/;

#$File::Find::current_dir = '.';

1;

__END__
