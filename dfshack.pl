#! /usr/bin/perl

use strict;
use warnings;

use Fuse;
use POSIX qw(setsid ENOENT ENOSYS ENOTDIR EEXIST EPERM EAGAIN O_RDONLY O_RDWR O_APPEND O_CREAT);
use Fcntl qw(S_ISBLK S_ISCHR S_ISFIFO SEEK_SET S_ISREG S_ISFIFO S_IMODE S_ISCHR S_ISBLK S_ISSOCK S_IRWXU);
use Time::HiRes qw(time gettimeofday tv_interval usleep);
use Getopt::Long;
use Lchown qw(lchown);
use File::Basename;
use File::Spec::Functions qw(catdir catfile devnull tmpdir rootdir);
use File::Util qw(SL); # since File::Spec has no way to directly access the path separator
use Fcntl qw(:mode);
use Filesys::Statvfs;

use Data::Dumper;

our $datadir = catdir(rootdir(), ".dfshack");

our %extraopts = (
		'threaded' => 0,
		'debug' => 0,
		'mountopts' => '',
		);

our $dfsmount;
our $mountpoint;
our $pidfile;

GetOptions(
		'debug' => sub {
			$extraopts{'debug'} = 1;
		},
		'use-threads' => sub {
			$extraopts{'threaded'} = 0; # NO THREADS FOR YOU
		},
		'dfs=s' => \$dfsmount,
		'mount=s' => \$mountpoint,
		'pidfile=s' => \$pidfile,
		'o=s' => \$extraopts{'mountopts'},
) or die "could not parse options";

our %symlinks = ();
our $symlinkupdate = undef;

our %permissions = ();
our $permissionsupdate = undef;

sub checklock {
	my $lock = shift;
	my $lockfile = fixup(catfile($datadir, ".$lock"));

	my $start = [gettimeofday];
	my $elapsed = $start;

	while((-e $lockfile) && $elapsed < 5) {
		print $elapsed . "\n";
		usleep(10_000); #Wait for .1 second
		$elapsed = tv_interval($start);
	}

	if(-e $lockfile) {
		return -EAGAIN();
	}

	return undef;
}

sub readfile {
	my $readtype = shift;
	my $hash = shift;
	my $modified = shift;

	my $filename = fixup(catfile($datadir, "$readtype"));
	
	debug("readfile: " . $filename);

# No symlinks file -- we have nothing to read!
	if(! -e $filename) {
		%$hash = ();
		debug("readfile: no file to read");
		return undef;
	}	
	
# Check to see if we're busy writing; hang for a while
# and then either carry on or fail
	my $rv = checklock($readtype);
	return $rv if $rv;

  my $mtime = (stat($filename))[9];

# If we're already up-to-date, don't bother
# reading the file.
	if($$modified) {
		if($mtime == $$modified) {
			debug("readfile: up-to-date");
			return undef;
		}
	}

# Update the modified time
	$$modified = $mtime;
	
	%$hash = ();

	open(my $fh, '<', $filename);

# Read the null-delimited file
	while(my $line = <$fh>) {
		if($line =~ /(.+)\0(.+)/) {
			$hash->{$1} = $2;
		}
	}

	close($fh);

	return undef;
}

sub writefile {
	my $writetype = shift;
	my $hash = shift;
	my $modified = shift;

	my $filename = fixup(catfile($datadir, "$writetype"));

	debug("writefile: " . $filename);

	my $rv = checklock($writetype);
	return $rv if $rv;

	if(-e $filename && ($$modified > (stat($filename))[9])) {
		debug("WARNING: link file modified in the future?");
	}

	open(my $lock, '>', fixup(catfile($datadir, ".$writetype")));
	close($lock);

	open(my $fh, '>', $filename);

	while(my($k, $v) = each(%$hash)) {
		print $fh $k . "\0" . $v . "\n";
	}

	close($fh);

	unlink(fixup(catfile($datadir,".$writetype")));

	return undef;
}

sub writelinks {
	return writefile("symlinks", \%symlinks, \$symlinkupdate);
}

sub readlinks {
	return readfile("symlinks", \%symlinks, \$symlinkupdate);
}

sub writepermissions {
	return writefile("permissions", \%permissions, \$permissionsupdate);
}

sub readpermissions {
	return readfile("permissions", \%permissions, \$permissionsupdate);
}

sub debug {
	my $string = shift;
	print $string . "\n" if($extraopts{'debug'} && $string);
	print "nothing to print here\n" if($extraopts{'debug'}) && !$string;
}

sub fixup {
	my $file = shift;
	return catfile($dfsmount, $file);
}

sub d_getattr {
	my $file = shift;
	my @stats;

	debug("d_getattr: " . $file);

	# Update cached data
	return -$! if readlinks();
	return -$! if readpermissions();

	if(my $link = $symlinks{$file}) {
		debug("d_getattr: is symlink");
		@stats = lstat(fixup(catfile($datadir, "symlinks")));

		my $linkfile = fixup(catfile(dirname($file), $file));
		if(-e $linkfile) {
			my @lstats = lstat($linkfile);
			$stats[9] = $lstats[9];
			$stats[10] = $lstats[10];
			$stats[11] = $lstats[11];
		}

		$stats[8] = length($link);

		# Convert the mode from a regular file to a link
		$stats[2] = (($stats[2] & !S_IFREG) | S_IFLNK);
	}
	else {
		debug("d_getattr: is regular file");

		@stats = lstat(fixup($file));
		debug("d_getattr: lstat returned nothing") unless @stats;
	}

	if($permissions{$file}) {
		if(@stats){
			debug("d_getattr: modifying permissions");
			$stats[2] = (($stats[2] & !S_IRWXU) | $permissions{$file});
		}
		else {
			# The file was deleted outside of dfshack; fuggedaboutit
			debug("d_getattr: file does not exist; forgetting permissions");
			if(delete $permissions{$file}) {
				writepermissions();
			}
		}
	}
		
	return -$! unless @stats;
	return @stats;
}

sub d_getdir {
	my $dirname = shift;
	debug("d_getdir: " . $dirname);

	return -EAGAIN() if readlinks();

	opendir(my $dir, fixup($dirname)) || return -ENOENT();

	my @files = readdir($dir);
	closedir($dir);

	foreach my $k (keys(%symlinks)) {
		debug("d_getdir link: " . $k);
		push(@files, basename($k)) if($k =~ /^\Q$dirname\E\Q${\SL}\E?[^\q${\SL}\E]+$/);
	}

	return (@files, 0);
}

sub d_open {
	my $file = shift;
	my $mode = shift;
	debug("d_open: " . $file);

	sysopen(my $fh, fixup($file), $mode) || return -$!;

	close($fh);
	return 0;
}

sub d_read {
	my $file = shift;
	my $bufsize = shift;
	my $offset = shift;
	my $rv = -ENOSYS();

	debug("d_read: " . $file);

	$file = fixup($file);

	return -ENOENT() unless -e($file);
	
	my $size = -s $file;

	open(my $handle, $file) or return -ENOSYS();
	if(seek($handle, $offset, SEEK_SET)) {
		read($handle, $rv, $bufsize);
	}

	return $rv;
}

sub d_write {
	my $file = shift;
	my $buf = shift;
	my $off = shift;
	my $rv;
	debug("d_write: " . $file);
	
	$file = fixup($file);
	
	return -ENOENT() unless -e($file); 
	my $fsize = -s $file;

	return -ENOSYS() unless open(my $fh, '+<', $file);
	if($rv = seek($fh, $off, SEEK_SET)) {
		$rv = print $fh $buf;
	}
	$rv or $rv = -ENOSYS();
	close($fh);
	return length($buf);
}

sub err {
	return (-shift || -$!);
}

sub d_readlink {
	my $file = shift;
	debug("d_readlink: " . $file);
	my $rv  = readlinks();

# fail on readlinks() error
	if($rv) {
		$! = $rv;
		return undef;
	}

	$rv = $symlinks{$file};
	$! = -ENOENT() unless $rv; # Is this right?
	return $rv;
}

sub d_unlink {
	my $file = shift;
	debug("d_unlink: " . $file);
	
	return -$! if readlinks();
	return -$! if readpermissions();

	if(delete $permissions{$file}) {
		writepermissions();
	}

	if(delete $symlinks{$file}) {
		writelinks();
		return 0;
	}

	local $!;
	unlink(fixup($file));
	return -$!;
}

sub d_symlink {
	my $old = shift;
	my $new = shift;

	debug("d_symlink: " . $old . " " . $new);
	
	return 0 if readlinks();

	if(-e fixup($new) || $symlinks{$new}) {
		debug("d_symlink: $new exists");
		return 0; #fail
	}

	$symlinks{$new} = $old;
	my $rv = writelinks();
	if($rv) {
		debug("d_symlink: failed to write link file");
		delete $symlinks{$new};
		return 0;
	}

	debug("d_symlink: success!");

	return undef;
}

sub d_link {
	my $old = shift;
	my $new = shift;

	debug("d_link: " . $old . ' ' . $new);

	return link(fixup($old), fixup($new)) ? 0 : -$!;
}

sub d_rename {
	my $old = shift;
	my $new = shift;
	debug("d_rename: " . $old . " " . $new);

	my $rv; 
	my $ret;

	return $rv if $rv = readlinks();
	return $rv if $rv = readpermissions();

	if(-d fixup($old)) {
		foreach my $file (keys %symlinks) {
			debug("d_rename: " . $file);
			if($file =~ /^\Q$old\E\Q${\SL}\E(.+)/) {
				$symlinks{catfile($new, $1)} = delete $symlinks{$file};
			}
		}
		foreach my $file (keys %permissions) {
			# match both files in the directory and the directory itself.
			if($file =~ /^\Q$old\E\Q${\SL}\E(.+|)/) { 
				$permissions{catfile($new, $1)} = delete $permissions{$file};
			}
		}
	}

	if($permissions{$old}) {
		$permissions{$new} = delete $permissions{$old};
	}
	
	if($symlinks{$old}) {
		$symlinks{$new} = delete $symlinks{$old};
		$ret = 0;
	}
	else {
		$ret = rename(fixup($old), fixup($new)) ? 0 : -ENOENT();
	}

	return $rv if $rv = writelinks();
	return $rv if $rv = writepermissions();

  return $ret;
}

sub d_chown {
	my $file = shift;
	my $uid = shift;
	my $gid = shift;
	
	debug("d_chown: " . $file);

	$file = fixup($file);

	local $!;
	debug("d_chown: no file $file") unless -e $file;
	lchown($uid, $gid, $file);

	return -$!;
}

sub d_chmod {
	my $file = shift;
	my $mode = shift;
	debug("d_chmod: " . $file);

	my $rv = readpermissions();
	if($rv) {
		return $rv;
	}

	$permissions{$file} = $mode;

	$rv = writepermissions();

	return 0 if !$rv;
	return $rv;
}

sub d_truncate {
	my $file = shift;
	my $length = shift;
	debug("d_truncate: " . $file);

	return truncate(fixup($file), $length) ? 0 : -$!;
}

sub d_utime {
	my $file = shift;
	my $atime = shift;
	my $utime = shift;
	debug("d_utime: " . $file);
	
	return utime($atime, $utime, fixup($file)) ? 0 : -$!;
}

sub d_mkdir {
	my $file = fixup(shift);
	my $perm = shift;
	debug("d_mkdir: " . $file);

	return mkdir($file, $perm) ? 0 : -$!;
}

sub d_rmdir {
	my $file = fixup(shift);
	debug("d_rmdir: " . $file);

	return rmdir($file) ? 0 : -$!;
}

sub d_mknod {
	my $file = shift;
	my $modes = shift;
	my $dev = shift;

	debug("d_mknod: " . $file);
	undef $!;

	return -EAGAIN() if readpermissions();

	if(S_ISREG($modes)) {
		open(my $fh, '>', fixup($file)) or return -$!;
		print $fh '';
		close $fh;
		$permissions{$file} = $modes;
		writepermissions();
		return 0;
	}
#	elsif (S_ISFIFO($modes)) {
#		return POSIX::mkfifo($file, S_IMODE($modes)) ? 0 : -POSIX::errno();
#	}
	elsif (S_ISCHR($modes) || S_ISBLK($modes)) {
		mknod ($file, $modes, $dev);
		return -$!;
	}
	#S_ISSOCK?
	else {
		return -ENOSYS();
	}
}

sub d_statfs {
	debug("d_statfs");
	return (statvfs($dfsmount))[1,2,3,5,6,9]; #from perl-fuse unit test
}

#from http://perldoc.perl.org/perlipc.html#Complete-Dissociation-of-Child-from-Parent
sub daemonize {
	chdir(rootdir()) || die "can't chdir to /: $!";
	open(STDIN, '<', devnull()) || die "can't read /dev/null: $!";

	my $outfile;
	if($extraopts{'debug'}) {
		debug("Pid: $$");
		$outfile = catfile(tmpdir(), "dfshack$$");
	}
	else {
		$outfile = devnull();
	}
	open(STDOUT, '>', $outfile) || die "can't write to $outfile: $!";
	defined(my $pid = fork()) || die "can't fork: $!";
	exit if $pid; # non-zero now means I am the parent
	(setsid() != -1) || die "Can't start a new session: $!";
	open(STDERR, ">&STDOUT") || die "can't dup stdout: $!";
}

sub is_mounted {
	debug("checkmounts");
	if((stat($mountpoint))[0] == (stat(File::Spec->catdir($mountpoint, '..')))[0]) {
		debug("checkmounts: not mounted");
		return undef;
	}
	else {
		debug("checkmounts: $mountpoint already mounted");
		return 1;
	}
}

$dfsmount = shift(@ARGV) if (!$dfsmount && @ARGV);
$mountpoint = shift(@ARGV) if (!$mountpoint && @ARGV);

if(! -e "$mountpoint") {
	die "ERROR: attempted to mount to nonexistent directory $mountpoint\n";
	return -ENOTDIR();
}

if(! -e $dfsmount ) {
	die "Invalid dfs mount point $dfsmount\n";
}

if(! -d $dfsmount ) {
	die "dfs mount $dfsmount is not a directory.\n";
}

is_mounted() and die "$mountpoint is already mounted!\n";

$extraopts{'debug'} or daemonize();

if(! -d fixup($datadir)) {
	mkdir(fixup($datadir), 0777);
}

Fuse::main(
		'mountpoint' => $mountpoint,
		'getattr' => 'main::d_getattr',
		'readlink' => 'main::d_readlink',
		'getdir' => 'main::d_getdir',
		'mknod' => 'main::d_mknod',
		'mkdir' => 'main::d_mkdir',
		'unlink' => 'main::d_unlink',
		'rmdir' => 'main::d_rmdir',
		'symlink' => 'main::d_symlink',
		'rename' => 'main::d_rename',
		'link' => 'main::d_link',
		'chmod' => 'main::d_chmod',
		'chown' => 'main::d_chown',
		'truncate' => 'main::d_truncate',
		'utime' => 'main::d_utime',
		'open' => 'main::d_open',
		'read' => 'main::d_read',
		'write' => 'main::d_write',
		'statfs' => 'main::d_statfs',
		%extraopts,
		);

