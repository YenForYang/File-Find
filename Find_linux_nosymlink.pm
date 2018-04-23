package File::Find;
#requires 5.006 or above
use strict;

# Should ideally be my() not our() but local() currently
# refuses to operate on lexicals

our (
	%SLnkSeen,

	$wanted_callback, $bydepth, $no_chdir,
	$follow_skip, $full_check,
	$pre_process, $post_process, $dangling_symlinks,

	$dir, $name, $fullname, $prune,

	$topdir, $topdev, $topino, $topmode, $topnlink, # for compatibility reasons (find.pl, find2perl)

	%skipit #my creations
);
%skipit = ('.',1,'..',1);

sub _find_opt {
    my $wanted = shift;
    die "invalid top directory" unless $_[0];

    # This function must local()ize everything because callbacks may call us again

    local(
		%SLnkSeen,
		$wanted_callback, $bydepth, $no_chdir,
        $follow_skip,
        $pre_process, $post_process, $dangling_symlinks,

		$dir, $name, $fullname, $prune,

		$topdir, $topdev, $topino, $topmode, $topnlink,
	);
    local *_ = \my $a;


	### modified version of ryfastcwd_linux() (not very "safe") ###
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
	### end of ryfastcwd_linux() ###

    $wanted_callback   = $wanted->{wanted};
    $bydepth           = $wanted->{bydepth};
    $pre_process       = $wanted->{preprocess};
    $post_process      = $wanted->{postprocess};
    $no_chdir          = $wanted->{no_chdir};
    $follow_skip       = $wanted->{follow_skip};
    $dangling_symlinks = $wanted->{dangling_symlinks};

    Proc_Top_Item:
    for my $TOP (@_) {
        #$topdir = $TOP;

        ($topdev,$topino,$topmode,$topnlink) = lstat $TOP;

		length $TOP > 1
			and substr($TOP, -1) eq '/' && chop $TOP;

		$topnlink //
			warn 'Cant stat ',$TOP,': ',$! and next;

		if (-d _) {
			my (
				$CdLvl,$Level,
				@Stack,@filenames,
				$subcount,
				$dir_pref,
				$SE,$dir_name,$dir_rel,
				$p_dir,$nlink,$tmp
			);
			$SE			= [];
			$dir_name	= $TOP;
			$dir_rel	= '.';

			$dir_pref	= $TOP eq '/' ? '/' : $TOP.'/';

			local ($dir, $name, $prune, *DIR);

				chdir $TOP or warn 'Cant cd to ',$TOP,': ',$! and return
			unless $no_chdir || $TOP eq '.';

			# push the starting directory
			push @Stack, [$CdLvl,$TOP,$dir_rel,-1] if $bydepth;

			while (defined $SE) {
				unless ($bydepth) {
					$dir	= $TOP; # $File::Find::dir
					$name	= $dir_name; # $File::Find::name
					$_		= $no_chdir ? $dir_name : $dir_rel;
					# prune may happen here
					$wanted_callback->();        # protect against wild "next"
					next if $prune;
				}

				(
					chdir $dir_rel or
						warn "Can't cd to (", $TOP ne '/' ? $TOP : '', '/) ',$dir_rel,': ',$! and next
				)
				&& ++$CdLvl unless $no_chdir || $dir_rel eq '.';

				$dir = $dir_name; # $File::Find::dir

				# Get the list of files in the current directory.
				opendir DIR, $no_chdir ? $dir_name : '.' or warn 'Cant opendir(',$dir_name,'): ',$! and next;

				@filenames = $pre_process ? $pre_process->(readdir DIR) : readdir DIR;

				push @Stack, [$CdLvl,$dir_name,'',-2] if $post_process;

				if ($topnlink == 2) {
					# This dir has no subdirectories.
					for my $FN (@filenames) {
						next if $skipit{$FN};
						$name = $dir_pref . $FN; # $File::Find::name
						$_ = $no_chdir ? $name : $FN; # $_
						$wanted_callback->();
					}
				} else {
					# This dir has subdirectories.
					$subcount = $topnlink - 2;
					# HACK: insert directories at this position, so as to preserve
					# the user pre-processed ordering of files (thus ensuring
					# directory traversal is in user sorted order, not at random).
					my $stack_top = @Stack;

					for my $FN (@filenames) {
						next if $skipit{$FN};

						# Seen all the subdirs? check for directoriness. stat is faster for a file in the current directory
						( $subcount > 0 || $topnlink < 2 # if dir has wrong nlink count, force switch to slower stat method
								and ( (lstat($no_chdir ? $dir_pref . $FN : $FN))[2] & 61440 ) == 16384 ) # S_IFMT assumed to be 61440, S_IFDIR = 16384;

							and splice(@Stack, $stack_top, 0, [ $CdLvl,$dir_name,$FN,(lstat _)[3] ]) || --$subcount;
								#HACKS: replace push to preserve dir traversal order; use 'or' as splice returns undef here.
						$name = $dir_pref . $FN; # $File::Find::name
						$_= $no_chdir ? $name : $FN; # $_
						$wanted_callback->();
					}
				}
			} continue {
				while ( defined ($SE = pop @Stack) ) {
					($Level, $p_dir, $dir_rel, $nlink) = @$SE;
					chdir( $tmp = join '/', ('..') x ($CdLvl-$Level) )
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
						substr($_, length == 2 ? -1 : -2) = '' if substr($_,-2) eq '/.';

						$wanted_callback->();
					} else {
						push @Stack,[$CdLvl,$p_dir,$dir_rel,-1] if $bydepth;
						last;
					}
				}
			}
		} else {
			substr($TOP,-1) ne '/' && $TOP
				and	(	$_ = '' and $dir = $TOP	)
				or	(	$dir = substr($_=$TOP, 0, rindex($TOP, '/')+1, '') || './'	and $topdir = $dir	);

			$no_chdir || chdir $topdir
				or warn 'Couldnt chdir ',$topdir,': ',$! and next Proc_Top_Item;

			$name = $topdir . $_;
			$_ = $name if $no_chdir;

			$wanted_callback->(); # REMOVED PROTECTION (curly brackets) against wild "next"!!!
		}

		die 'Cant cd to ',$cwd,': ',$! unless $no_chdir || chdir $cwd;
    }
}


# default
#$File::Find::skip_pattern    = qr/^\.{1,2}\z/;

#$File::Find::current_dir = '.';

1;
__END__
