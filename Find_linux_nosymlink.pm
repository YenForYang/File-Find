package File::Find;
use 5.006;
use strict;
use warnings;
use warnings::register;

our @ISA = qw(Exporter);

use strict;
my $Is_VMS;
my $Is_Win32;

require File::Basename;
require File::Spec;

# Should ideally be my() not our() but local() currently
# refuses to operate on lexicals

our %SLnkSeen;
our ($wanted_callback, $avoid_nlink, $bydepth, $no_chdir, $follow,
	$follow_skip, $full_check, $untaint, $untaint_skip, $untaint_pat,
	$pre_process, $post_process, $dangling_symlinks);

my $contract_name_rgx = qr'[^/]*/\.\./+';
sub contract_name { #($cdir,$fn)
	$_[1] eq $File::Find::current_dir
		&& return substr $_[0], 0, rindex $_[0], '/';

	substr($_[0],rindex($_[0],'/')+1) = '';

	$_ eq './' and $_ = '' for substr $_[1], 0, 2;

	my $abs_name = $_[0] . $_[1];

	if (substr($_[1],0,3) eq '../') {	1 while $abs_name =~ s !$contract_name_rgx!/!	}

	return $abs_name;
}

sub ryfastcwd_linux() { #Assumes OS is not Apollo, no tainting, and no unstable directory paths
    my($odev, $oino, $cdev, $cino, $tdev, $tino, $path);
	($cdev,$cino) = stat '.';
    while (
		($odev, $oino) = ($cdev, $cino),
		chdir '..',
		($cdev, $cino) = stat '.',
		$oino != $cino || $odev != $cdev
	) {
        opendir DIRHANDLE_fcwd, '.' or return;
        while (readdir DIRHANDLE_fcwd) {
            $_ eq '.' or $_ eq '..' and next;
            ($tdev, $tino) = lstat;
            $tino == $oino && $tdev == $odev
				and substr($path, 0, 0) = '/'.$_ and closedir DIRHANDLE_fcwd;
        }
    }
	chdir $path;
    $path;
}

our($dir, $name, $fullname, $prune);
sub _find_dir_symlnk($$$);
sub _find_dir($$$);

# ASSUME NO TAINT #

sub _find_opt {
	my $wanted = shift;
	return unless @_;
	die "invalid top directory" unless defined $_[0];

	# This function must local()ize everything because callbacks may
	# call find() or finddepth()

	local %SLnkSeen;
	local ($wanted_callback, $avoid_nlink, $bydepth, $no_chdir, $follow,
		$follow_skip, $full_check, $untaint, $untaint_skip, $untaint_pat,
		$pre_process, $post_process, $dangling_symlinks);
	local($dir, $name, $fullname, $prune);
	local *_ = \my $a;

	my $cwd = do { # ryfastcwd_linux()
		my($odev, $oino, $cdev, $cino, $tdev, $tino, $path);
		($cdev,$cino) = stat '.';
		while (
			($odev, $oino) = ($cdev, $cino),
			chdir '..',
			($cdev, $cino) = stat '.',
			$oino != $cino || $odev != $cdev
		) {
			opendir DIRHANDLEfcwd, '.' or return;
			while (readdir DIRHANDLEfcwd) {
				$_ eq '.' or $_ eq '..' and next;
				($tdev, $tino) = lstat;
				$tino == $oino && $tdev == $odev
					and substr($path, 0, 0) = '/'.$_ and closedir DIRHANDLEfcwd;
			}
		}
		chdir $path;
		$path;
	};
	$wanted_callback   = $wanted->{wanted};
	$bydepth           = $wanted->{bydepth};
	$pre_process       = $wanted->{preprocess};
	$post_process      = $wanted->{postprocess};
	$no_chdir          = $wanted->{no_chdir};
	$follow_skip       = $wanted->{follow_skip};
	$dangling_symlinks = $wanted->{dangling_symlinks};

	# for compatibility reasons (find.pl, find2perl)
	local our ($topdir, $topdev, $topino, $topmode, $topnlink);

	# a symbolic link to a directory doesn't increase the link count
	$avoid_nlink      = $follow || $File::Find::dont_use_nlink;

	my ($abs_dir, $Is_Dir);

	Proc_Top_Item:
	for my $TOP (@_) {
		my $top_item = $TOP;

		($topdev,$topino,$topmode,$topnlink) = lstat $top_item;

		length($top_item) > 1
			or substr($top_item, -1) eq '/' && chop;

		$topdir = $top_item;
		$topnlink //
			warnings::warnif "Can't stat $top_item: $!\n"
			&& next Proc_Top_Item;
		-d _
			and _find_dir($wanted, $top_item, $topnlink)
				&& ++$Is_Dir
			or $abs_dir=$top_item;

		unless ($Is_Dir) {

			substr($abs_dir,-1) ne '/' && $abs_dir
				and	(	$_ = '' and $dir = $abs_dir	)
				or	(	$dir = substr($_=$abs_dir, 0, rindex($abs_dir, '/')+1, '') || './'	and $abs_dir = $dir	);

			$no_chdir || chdir $abs_dir
				or warnings::warnif "Couldn't chdir $abs_dir: $!\n" && next Proc_Top_Item;

			$name = $abs_dir . $_;
			$_ = $name if $no_chdir;

			{ $wanted_callback->() }; # protect against wild "next"

		}

		die "Can't cd to $cwd: $!\n" unless $no_chdir || chdir $cwd;
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
	my ($CdLvl,$Level) = (0,0);
	my @Stack;
	my @filenames;
	my ($subcount,$sub_nlink);
	my $SE= [];
	my $dir_name= $p_dir;
	my $dir_pref;
	my $dir_rel = $File::Find::current_dir;
	my $tainted = 0;
	my $no_nlink;

	if ($Is_Win32) {
		$dir_pref
		  = ($p_dir =~ m{^(?:\w:[/\\]?|[/\\])$} ? $p_dir : "$p_dir/" );
	} elsif ($Is_VMS) {

		#       VMS is returning trailing .dir on directories
		#       and trailing . on files and symbolic links
		#       in UNIX syntax.
		#

		$p_dir =~ s/\.(dir)?$//i unless $p_dir eq '.';

		$dir_pref = ($p_dir =~ m/[\]>]+$/ ? $p_dir : "$p_dir/" );
	}
	else {
		$dir_pref= ( $p_dir eq '/' ? '/' : "$p_dir/" );
	}

	local ($dir, $name, $prune, *DIR);

	unless ( $no_chdir || ($p_dir eq $File::Find::current_dir)) {
		my $udir = $p_dir;
		if (( $untaint ) && (is_tainted($p_dir) )) {
			( $udir ) = $p_dir =~ m|$untaint_pat|;
			unless (defined $udir) {
				if ($untaint_skip == 0) {
					die "directory $p_dir is still tainted";
				}
				else {
					return;
				}
			}
		}
		unless (chdir ($Is_VMS && $udir !~ /[\/\[<]+/ ? "./$udir" : $udir)) {
			warnings::warnif "Can't cd to $udir: $!\n";
			return;
		}
	}

	# push the starting directory
	push @Stack,[$CdLvl,$p_dir,$dir_rel,-1]  if  $bydepth;

	while (defined $SE) {
		unless ($bydepth) {
			$dir= $p_dir; # $File::Find::dir
			$name= $dir_name; # $File::Find::name
			$_= ($no_chdir ? $dir_name : $dir_rel ); # $_
			# prune may happen here
			$prune= 0;
			{ $wanted_callback->() };        # protect against wild "next"
			next if $prune;
		}

		# change to that directory
		unless ($no_chdir || ($dir_rel eq $File::Find::current_dir)) {
			my $udir= $dir_rel;
			if ( ($untaint) && (($tainted) || ($tainted = is_tainted($dir_rel) )) ) {
				( $udir ) = $dir_rel =~ m|$untaint_pat|;
				unless (defined $udir) {
					if ($untaint_skip == 0) {
						die "directory (" . ($p_dir ne '/' ? $p_dir : '') . "/) $dir_rel is still tainted";
					} else { # $untaint_skip == 1
						next;
					}
				}
			}
			unless (chdir ($Is_VMS && $udir !~ /[\/\[<]+/ ? "./$udir" : $udir)) {
				warnings::warnif "Can't cd to (" .
					($p_dir ne '/' ? $p_dir : '') . "/) $udir: $!\n";
				next;
			}
			$CdLvl++;
		}

		$dir= $dir_name; # $File::Find::dir

		# Get the list of files in the current directory.
		unless (opendir DIR, ($no_chdir ? $dir_name : $File::Find::current_dir)) {
			warnings::warnif "Can't opendir($dir_name): $!\n";
			next;
		}
		@filenames = readdir DIR;
		closedir(DIR);
		@filenames = $pre_process->(@filenames) if $pre_process;
		push @Stack,[$CdLvl,$dir_name,"",-2]   if $post_process;

		# default: use whatever was specified
		# (if $nlink >= 2, and $avoid_nlink == 0, this will switch back)
		$no_nlink = $avoid_nlink;
		# if dir has wrong nlink count, force switch to slower stat method
		$no_nlink = 1 if ($nlink < 2);

		if ($nlink == 2 && !$no_nlink) {
			# This dir has no subdirectories.
			for my $FN (@filenames) {
				if ($Is_VMS) {
				# Big hammer here - Compensate for VMS trailing . and .dir
				# No win situation until this is changed, but this
				# will handle the majority of the cases with breaking the fewest

					$FN =~ s/\.dir\z//i;
					$FN =~ s#\.$## if ($FN ne '.');
				}
				next if $FN =~ $File::Find::skip_pattern;

				$name = $dir_pref . $FN; # $File::Find::name
				$_ = ($no_chdir ? $name : $FN); # $_
				{ $wanted_callback->() }; # protect against wild "next"
			}

		}
		else {
			# This dir has subdirectories.
			$subcount = $nlink - 2;

			# HACK: insert directories at this position, so as to preserve
			# the user pre-processed ordering of files (thus ensuring
			# directory traversal is in user sorted order, not at random).
			my $stack_top = @Stack;

			for my $FN (@filenames) {
				next if $FN =~ $File::Find::skip_pattern;
				if ($subcount > 0 || $no_nlink) {
					# Seen all the subdirs?
					# check for directoriness.
					# stat is faster for a file in the current directory
					$sub_nlink = (lstat ($no_chdir ? $dir_pref . $FN : $FN))[3];

					if (-d _) {
						--$subcount;
						$FN =~ s/\.dir\z//i if $Is_VMS;
						# HACK: replace push to preserve dir traversal order
						#push @Stack,[$CdLvl,$dir_name,$FN,$sub_nlink];
						splice @Stack, $stack_top, 0,
								 [$CdLvl,$dir_name,$FN,$sub_nlink];
					}
					else {
						$name = $dir_pref . $FN; # $File::Find::name
						$_= ($no_chdir ? $name : $FN); # $_
						{ $wanted_callback->() }; # protect against wild "next"
					}
				}
				else {
					$name = $dir_pref . $FN; # $File::Find::name
					$_= ($no_chdir ? $name : $FN); # $_
					{ $wanted_callback->() }; # protect against wild "next"
				}
			}
		}
	}
	continue {
		while ( defined ($SE = pop @Stack) ) {
			($Level, $p_dir, $dir_rel, $nlink) = @$SE;
			if ($CdLvl > $Level && !$no_chdir) {
				my $tmp;
				if ($Is_VMS) {
					$tmp = '[' . ('-' x ($CdLvl-$Level)) . ']';
				}
				else {
					$tmp = join('/',('..') x ($CdLvl-$Level));
				}
				die "Can't cd to $tmp from $dir_name: $!"
					unless chdir ($tmp);
				$CdLvl = $Level;
			}

			if ($Is_Win32) {
				$dir_name = ($p_dir =~ m{^(?:\w:[/\\]?|[/\\])$}
					? "$p_dir$dir_rel" : "$p_dir/$dir_rel");
				$dir_pref = "$dir_name/";
			}
			elsif ($^O eq 'VMS') {
				if ($p_dir =~ m/[\]>]+$/) {
					$dir_name = $p_dir;
					$dir_name =~ s/([\]>]+)$/.$dir_rel$1/;
					$dir_pref = $dir_name;
				}
				else {
					$dir_name = "$p_dir/$dir_rel";
					$dir_pref = "$dir_name/";
				}
			}
			else {
				$dir_name = ($p_dir eq '/' ? "/$dir_rel" : "$p_dir/$dir_rel");
				$dir_pref = "$dir_name/";
			}

			if ( $nlink == -2 ) {
				$name = $dir = $p_dir; # $File::Find::name / dir
				$_ = $File::Find::current_dir;
				$post_process->();           # End-of-directory processing
			}
			elsif ( $nlink < 0 ) {  # must be finddepth, report dirname now
				$name = $dir_name;
				if ( substr($name,-2) eq '/.' ) {
					substr($name, length($name) == 2 ? -1 : -2) = '';
				}
				$dir = $p_dir;
				$_ = ($no_chdir ? $dir_name : $dir_rel );
				if ( substr($_,-2) eq '/.' ) {
					substr($_, length($_) == 2 ? -1 : -2) = '';
				}
				{ $wanted_callback->() }; # protect against wild "next"
			 }
			 else {
				push @Stack,[$CdLvl,$p_dir,$dir_rel,-1]  if  $bydepth;
				last;
			}
		}
	}
}

# default
$File::Find::skip_pattern    = qr/^\.{1,2}\z/;

$File::Find::current_dir = '.';

1;

__END__
