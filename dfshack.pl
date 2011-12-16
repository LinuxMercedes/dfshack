#! /usr/bin/perl

use strict;
use warnings;

use Fuse;
use POSIX qw(ENOENT ENOSYS ENOTDIR EEXIST EPERM EAGAIN O_RDONLY O_RDWR O_APPEND O_CREAT);
use Fcntl qw(S_ISBLK S_ISCHR S_ISFIFO SEEK_SET S_ISREG S_ISFIFO S_IMODE S_ISCHR S_ISBLK S_ISSOCK);
use Time::HiRes qw(time gettimeofday tv_interval usleep);
use Getopt::Long;
use Lchown qw(lchown);
use File::Basename;
use Data::Dumper;

our %extraopts = (
		'threaded' => 0,
		'debug' => 0,
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
) or die "could not parse options";

our %symlinks = ();
our $symlinkupdate = undef;

sub checklock {
	my $lock = shift;
	my $lockfile = fixup("/.dfshack/.$lock");

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

	my $filename = fixup("/.dfshack/$readtype");
	
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

	my $mtime = undef;

# If we're already up-to-date, don't bother
# reading the file.
	if($$modified) {
		$mtime = (stat($filename))[9];
		if($mtime == $$modified) {
			debug("readfile: up-to-date");
			return undef;
		}
	}

# Update the modified time
	$mtime = (stat($filename))[9] unless $mtime;
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

	my $filename = fixup("/.dfshack/$writetype");

	debug("writefile: " . $filename);

	my $rv = checklock($writetype);
	return $rv if $rv;

	if(-e $filename) {
		debug("writefile: $filename exists");
	}

	if(-e $filename && ($$modified > (stat($filename))[9])) {
		debug("WARNING: link file modified in the future?");
	}

	open(my $lock, '>', ".dfshack/.$writetype");
	close($lock);

	open(my $fh, '>', $filename);

	while(my($k, $v) = each(%$hash)) {
		print $fh $k . "\0" . $v . "\n";
	}

	close($fh);

	unlink(".dfshack/.$writetype");

	return undef;
}

sub writelinks {
	return writefile("symlinks", \%symlinks, \$symlinkupdate);
}

sub readlinks {
	return readfile("symlinks", \%symlinks, \$symlinkupdate);
}

sub debug {
	my $string = shift;
	print $string . "\n" if($extraopts{'debug'} && $string);
	print "nothing to print here\n" if($extraopts{'debug'});
}

sub fixup {
	my $file = shift;
	return $dfsmount . $file;
}

sub d_getattr {
	my $file = shift;
	my @stats;

	debug("d_getattr: " . $file);

	if(my $link = $symlinks{$file}) {
		@stats = lstat(fixup("/.dfshack/symlinks"));

		my $linkfile = fixup(dirname($file) . '/' . $file);
		if(-e $linkfile) {
			my @lstats = lstat($linkfile);
			$stats[9] = $lstats[9];
			$stats[10] = $lstats[10];
			$stats[11] = $lstats[11];
		}

		$stats[8] = length($link);
	}
	else {
		@stats = lstat(fixup($file));
	}

	return -$! unless @stats;
	return @stats;
}

sub d_getdir {
	my $dirname = fixup(shift);
	debug("d_getdir: " . $dirname);

	opendir(my $dir, $dirname) || return -ENOENT();

	my @files = readdir($dir);
	closedir($dir);

	foreach my $k (keys(%$symlinks)) {
		push(@files, $k) if($k =~ /^$dirname/);
	}

	return (@files, 0);
}

sub d_open {
	my $file = fixup(shift);
	my $mode = shift;
	debug("d_open: " . $file);

	sysopen(my $fh, $file, $mode) || return -$!;

	close($fh);
	return 0;
}

sub d_read {
	my $file = fixup(shift);
	my $bufsize = shift;
	my $offset = shift;
	my $rv = -ENOSYS();

	debug("d_read: " . $file);
	return -ENOENT() unless -e($file); # = fixup($file)
	
	my $size = -s $file;

	open(my $handle, $file) or return -ENOSYS();
	if(seek($handle, $offset, SEEK_SET)) {
		read($handle, $rv, $bufsize);
	}

	return $rv;
}

sub d_write {
	my $file = fixup(shift);
	my $buf = shift;
	my $off = shift;
	my $rv;
	debug("d_write: " . $file);
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
	print "readlink\n";
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
	my $file = fixup(shift);
	debug("d_unlink: " . $file);
	print "unlink\n";
	my $result = delete $symlinks{$file};
	
  return 0 if $result;

	local $!;
	unlink($file);
	return -$!;
}

sub d_symlink {
	my $old = shift;
	my $new = shift;
	my $absold = dirname($new) . '/' . $old;

	debug("d_symlink: " . $absold . " " . $new);
	if(! -e fixup($absold) || -e fixup($new) || $symlinks{$old} || $symlinks{$new}) {
#		return -EEXISTS();
		debug("d_symlink: something exists or doesn't");
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

	return 1;
}

sub d_link {
	print "hardlink\n";
	debug("d_link: " . shift);
#	return link(fixup(shift), fixup(shift)) ? 0 : -$!;
	return -ENOSYS();
}

sub d_rename {
	my $old = fixup(shift);
	my $new = fixup(shift);
	debug("d_rename: " . $old . " " . $new);
  return rename($old, $new) ? 0 : -ENOENT();
}

sub d_chown {
	my $file = fixup(shift);
	my $uid = shift;
	my $gid = shift;
	
	debug("d_chown: " . $file);

	local $!; #huh?
	print "no file $file\n" unless -e $file;
	lchown($uid, $gid, $file);

	return -$!;
}

sub d_chmod {
	my $file = fixup(shift);
	my $mode = shift;
	debug("d_chmod: " . $file);

	return chmod($mode, $file) ? 0 : -$!;
}

sub d_truncate {
	my $file = fixup(shift);
	my $length = shift;
	debug("d_truncate: " . $file);

	return truncate($file, $length) ? 0 : -$!;
}

sub d_utime {
	my $file = fixup(shift);
	my $atime = shift;
	my $utime = shift;
	debug("d_utime: " . $file);

	return utime($atime, $utime, $file) ? 0 : -$!;
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
	my $file = fixup(shift);
	my $modes = shift;
	my $dev = shift;

	debug("d_mknod: " . $file);
	undef $!;

	if(S_ISREG($modes)) {
		open(my $fh, '>', $file) or return -$!;
		print $fh '';
		close $fh;
		chmod S_IMODE($modes), $file;
		return 0;
	}
	elsif (S_ISFIFO($modes)) {
		return POSIX::mkfifo($file, S_IMODE($modes)) ? 0 : -POSIX::errno();
	}
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
	return -ENOSYS(); #lol suckers
}

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

if(!$extraopts{'debug'}) {
my $pid = fork();
defined $pid or die "fork() failed: $!";

if($pid > 0) { #parent
	exit(0);
}

if($pidfile) { # child
	open(my $pfh, '>', $pidfile);
	print $pfh $$, "\n";
	close $pfh;
}

}

if(! -d fixup("/.dfshack")) {
	mkdir(fixup("/.dfshack"), 0777);
}

readlinks();

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

