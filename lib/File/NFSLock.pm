# -*- perl -*-
#
#  File::NFSLock - bdpO - NFS compatible (safe) locking utility
#
#  $Id: NFSLock.pm,v 1.15 2002/05/31 18:14:16 hookbot Exp $
#
#  Copyright (C) 2002, Paul T Seamons
#                      paul@seamons.com
#                      http://seamons.com/
#
#                      Rob B Brown
#                      rob@roobik.com
#
#  This package may be distributed under the terms of either the
#  GNU General Public License
#    or the
#  Perl Artistic License
#
#  All rights reserved.
#
#  Please read the perldoc File::NFSLock
#
################################################################

package File::NFSLock;

use strict;
use Exporter ();
use vars qw(@ISA @EXPORT_OK $VERSION $TYPES
            $LOCK_EXTENSION $HOSTNAME $errstr);
use Carp qw(croak confess);

@ISA = qw(Exporter);
@EXPORT_OK = qw(uncache);

$VERSION = '1.14';

#Get constants, but without the bloat of
#use Fcntl qw(LOCK_SH LOCK_EX LOCK_NB);
sub LOCK_SH {1}
sub LOCK_EX {2}
sub LOCK_NB {4}

### Convert lock_type to a number
$TYPES = {
  BLOCKING    => LOCK_EX,
  BL          => LOCK_EX,
  EXCLUSIVE   => LOCK_EX,
  EX          => LOCK_EX,
  NONBLOCKING => LOCK_EX | LOCK_NB,
  NB          => LOCK_EX | LOCK_NB,
  SHARED      => LOCK_SH,
  SH          => LOCK_SH,
};
$LOCK_EXTENSION = '.NFSLock'; # customizable extension
$HOSTNAME = undef;

###----------------------------------------------------------------###

sub new {
  $errstr = undef;

  my $type  = shift;
  my $class = ref($type) || $type || __PACKAGE__;
  my $self  = {};

  ### allow for arguments by hash ref or serially
  if( @_ && ref $_[0] ){
    $self = shift;
  }else{
    $self->{file}      = shift;
    $self->{lock_type} = shift;
    $self->{blocking_timeout}   = shift;
    $self->{stale_lock_timeout} = shift;
  }
  $self->{file}       ||= "";
  $self->{lock_type}  ||= 0;
  $self->{blocking_timeout}   ||= 0;
  $self->{stale_lock_timeout} ||= 0;
  $self->{unlocked} = 1;

  ### force lock_type to be numerical
  if( $self->{lock_type} &&
      $self->{lock_type} !~ /^\d+/ &&
      exists $TYPES->{$self->{lock_type}} ){
    $self->{lock_type} = $TYPES->{$self->{lock_type}};
  }

  croak ($errstr = "Unrecognized lock_type operation setting [$self->{lock_type}]")
    unless $self->{lock_type} && $self->{lock_type} =~ /^\d+/;

  ### need the hostname
  if( !$HOSTNAME ){
    require Sys::Hostname;
    $HOSTNAME = &Sys::Hostname::hostname();
  }

  ### quick usage check
  croak ($errstr = "Usage: my \$f = File::NFSLock->new('/pathtofile/file',\n"
         ."'BLOCKING|EXCLUSIVE|NONBLOCKING|SHARED', [blocking_timeout, stale_lock_timeout]);\n"
         ."(You passed \"$self->{file}\" and \"$self->{lock_type}\")")
    unless length($self->{file});

  ### Input syntax checking passed, ready to bless
  bless $self, $class;

  ### choose a random filename
  $self->{rand_file} = rand_file( $self->{file} );

  ### choose the lock filename
  $self->{lock_file} = $self->{file} . $LOCK_EXTENSION;

  my $quit_time = $self->{blocking_timeout} &&
    !($self->{lock_type} & LOCK_NB) ?
      time() + $self->{blocking_timeout} : 0;

  ### remove an old lockfile if it is older than the stale_timeout
  if( -e $self->{lock_file} && $self->{stale_lock_timeout} > 0 ){
    # If it's older than stale_lock_timeout, wipe it.
    if ( time() - (stat _)[9] > $self->{stale_lock_timeout} ){ # check mtime
      unlink $self->{lock_file};
    }
  }

  while (1) {
    ### open the temporary file
    $self->create_magic
      or return undef;

    if ( $self->{lock_type} & LOCK_EX ) {
      last if $self->do_lock;
    } elsif ( $self->{lock_type} & LOCK_SH ) {
      last if $self->do_lock_shared;
    } else {
      $errstr = "Unknown lock_type [$self->{lock_type}]";
      return undef;
    }

    ### Lock failed!
    ### If non-blocking, then kick out now.
    ### ($errstr might already be set to the reason.)
    if ($self->{lock_type} & LOCK_NB) {
      $errstr ||= "NONBLOCKING lock failed!";
      return undef;
    }

    ### wait a moment
    sleep(1);

    ### but don't wait past the time out
    if( $quit_time && (time > $quit_time) ){
      $errstr = "Timed out waiting for blocking lock";
      return undef;
    }

    # BLOCKING Lock, So Keep Trying
  }

  ### clear up the NFS cache
  $self->uncache;

  ### Yes, the lock has been aquired.
  delete $self->{unlocked};

  return $self;
}

sub DESTROY {
  shift()->unlock();
}

sub unlock ($) {
  my $self = shift;
  if (!$self->{unlocked}) {
    unlink( $self->{rand_file} ) if -e $self->{rand_file};
    if( $self->{lock_type} & LOCK_SH ){
      return $self->do_unlock_shared( $self->{lock_file}, $self->{lock_line} );
    }else{
      return $self->do_unlock( $self->{lock_file} );
    }
    $self->{unlocked} = 1;
  }
  return 1;
}

###----------------------------------------------------------------###

# concepts for these routines were taken from Mail::Box which
# took the concepts from Mail::Folder


sub rand_file ($) {
  my $file = shift;
  "$file.tmp.". time()%10000 .'.'. $$ .'.'. int(rand()*10000);
}

sub create_magic ($;$) {
  $errstr = undef;
  my $self = shift;
  my $append_file = shift || $self->{rand_file};
  $self->{lock_line} ||= "$HOSTNAME $$ ".time()." ".int(rand()*10000)."\n";
  local *_FH;
  open (_FH,">>$append_file") or do { $errstr = "Couldn't open \"$append_file\" [$!]"; return undef; };
  print _FH $self->{lock_line};
  close _FH;
  return 1;
}

sub do_lock {
  $errstr = undef;
  my $self = shift;
  my $lock_file = $self->{lock_file};
  my $rand_file = $self->{rand_file};
  my $chmod = 0600;
  chmod( $chmod, $rand_file)
    || die "I need ability to chmod files to adequatetly perform locking";

  ### try a hard link, if it worked
  ### two files are pointing to $rand_file
  my $success = link( $rand_file, $lock_file )
    && -e $rand_file && (stat _)[3] == 2;
  unlink $rand_file;

  return $success;
}

sub do_lock_shared {
  $errstr = undef;
  my $self = shift;
  my $lock_file  = $self->{lock_file};
  my $rand_file  = $self->{rand_file};

  ### chmod local file to make sure we know before
  my $chmod = 0600;
  my $bit   = 1;
  $chmod |= $bit;
  chmod( $chmod, $rand_file)
    || die "I need ability to chmod files to adequatetly perform locking";

  ### lock the locking process
  local $LOCK_EXTENSION = ".shared";
  my $lock = new File::NFSLock {
    file => $lock_file,
    lock_type => LOCK_EX,
    blocking_timeout => 62,
    stale_lock_timeout => 60,
  };
  # The ".shared" lock will be released as this status
  # is returned, whether or not the status is successful.

  ### If I didn't have exclusive and the shared bit is not
  ### set, I have failed

  ### Try to create $lock_file from the special
  ### file with the magic $bit set.
  my $success = link( $rand_file, $lock_file);
  unlink $rand_file;
  if ( !$success ) {
    if (-e $lock_file) {
      if( ((stat _)[2] & $bit) != $bit ){
        $errstr = "Exclusive lock exists.";
        return undef;
      }
    } else {
      # $lock_file does not exist? Race condition? Permission denied?
    }
    # Looks like there already exists a share lock.
    # So must be able to obtain another shared lock.
    # Append my magic line too.
    $self->create_magic ($self->{lock_file});
  } else {
    # Very first process to obtain a shared lock.
  }
  # Success
  return 1;
}

sub do_unlock ($) {
  return unlink shift->{lock_file};
}

sub do_unlock_shared ($$) {
  $errstr = undef;
  my $self = shift;
  my $lock_file = $self->{lock_file};
  my $lock_line = $self->{lock_line};

  ### lock the locking process
  local $LOCK_EXTENSION = '.shared';
  my $lock = new File::NFSLock ($lock_file,LOCK_EX,62,60);

  ### get the handle on the lock file
  local *_FH;
  if( ! open (_FH,"+<$lock_file") ){
    if( ! -e $lock_file ){
      return 1;
    }else{
      die "Could not open for writing shared lock file $lock_file ($!)";
    }
  }

  ### read existing file
  my $content = '';
  while(defined(my $line=<_FH>)){
    next if $line eq $lock_line;
    $content .= $line;
  }

  ### other shared locks exist
  if( length($content) ){
    seek     _FH, 0, 0;
    print    _FH $content;
    truncate _FH, length($content);
    close    _FH;

  ### only I exist
  }else{
    close _FH;
    unlink $lock_file;
  }

}

sub uncache ($;$) {
  # allow as method call
  my $file = pop;
  ref $file && ($file = $file->{file});
  my $rand_file = rand_file( $file );

  ### hard link to the actual file which will bring it up to date
  return ( link( $file, $rand_file) && unlink($rand_file) );
}

1;


=head1 NAME

File::NFSLock - perl module to do NFS (or not) locking

=head1 SYNOPSIS

  use File::NFSLock qw(uncache);
  use Fcntl qw(LOCK_EX LOCK_NB);

  my $file = "somefile";

  ### set up a lock - lasts until object looses scope
  if (my $lock = new File::NFSLock {
    file      => $file,
    lock_type => LOCK_EX|LOCK_NB,
    blocking_timeout   => 10,      # 10 sec
    stale_lock_timeout => 30 * 60, # 30 min
  }) {

    ### OR
    ### my $lock = File::NFSLock->new($file,LOCK_EX|LOCK_NB,10,30*60);

    ### do write protected stuff on $file
    ### at this point $file is uncached from NFS (most recent)
    open(FILE, "+<$file") || die $!;

    ### or open it any way you like
    ### my $fh = IO::File->open( $file, 'w' ) || die $!

    ### update (uncache across NFS) other files
    uncache("someotherfile1");
    uncache("someotherfile2");
    # open(FILE2,"someotherfile1");

    ### unlock it
    $lock->unlock();
    ### OR
    ### undef $lock;
    ### OR let $lock go out of scope
  }else{
    die "I couldn't lock the file [$File::NFSLock::errstr]";
  }


=head1 DESCRIPTION

Program based of concept of hard linking of files being atomic across
NFS.  This concept was mentioned in Mail::Box::Locker (which was
originally presented in Mail::Folder::Maildir).  Some routine flow is
taken from there -- particularly the idea of creating a random local
file, hard linking a common file to the local file, and then checking
the nlink status.  Some ideologies were not complete (uncache
mechanism, shared locking) and some coding was even incorrect (wrong
stat index).  File::NFSLock was written to be light, generic,
and fast.


=head1 USAGE

Locking occurs by creating a File::NFSLock object.  If the object
is created successfully, a lock is currently in place and remains in
place until the lock object goes out of scope (or calls the unlock
method).

A lock object is created by calling the new method and passing two
to four parameters in the following manner:

  my $lock = File::NFSLock->new($file,
                                $lock_type,
                                $blocking_timeout,
                                $stale_lock_timeout,
                                );

Additionally, parameters may be passed as a hashref:

  my $lock = File::NFSLock->new({
    file               => $file,
    lock_type          => $lock_type,
    blocking_timeout   => $blocking_timeout,
    stale_lock_timeout => $stale_lock_timeout,
  });

=head1 PARAMETERS

=over 4

=item Parameter 1: file

Filename of the file upon which it is anticipated that a write will
happen to.  Locking will provide the most recent version (uncached)
of this file upon a successful file lock.  It is not necessary
for this file to exist.

=item Parameter 2: lock_type

Lock type must be one of the following:

  BLOCKING
  BL
  EXCLUSIVE (BLOCKING)
  EX
  NONBLOCKING
  NB
  SHARED
  SH

Or else one or more of the following joined with '|':

  Fcntl::LOCK_EX() (BLOCKING)
  Fcntl::LOCK_NB() (NONBLOCKING)
  Fcntl::LOCK_SH() (SHARED)

Lock type determines whether the lock will be blocking, non blocking,
or shared.  Blocking locks will wait until other locks are removed
before the process continues.  Non blocking locks will return undef if
another process currently has the lock.  Shared will allow other
process to do a shared lock at the same time as long as there is not
already an exclusive lock obtained.

=item Parameter 3: blocking_timeout (optional)

Timeout is used in conjunction with a blocking timeout.  If specified,
File::NFSLock will block up to the number of seconds specified in
timeout before returning undef (could not get a lock).


=item Parameter 4: stale_lock_timeout (optional)

Timeout is used to see if an existing lock file is older than the stale
lock timeout.  If do_lock fails to get a lock, the modified time is checked
and do_lock is attempted again.  If the stale_lock_timeout is set to low, a
recursion load could exist so do_lock will only recurse 10 times (this is only
a problem if the stale_lock_timeout is set too low -- on the order of one or two
seconds).

=head1 FAILURE

On failure, a global variable, $File::NFSLock::errstr, should be set and should
contain the cause for the failure to get a lock.  Useful primarily for debugging.

=head1 LOCK_EXTENSION

By default File::NFSLock will use a lock file extenstion of ".NFSLock".  This is
in a global variable $File::NFSLock::LOCK_EXTENSION that may be changed to
suit other purposes (such as compatibility in mail systems).

=head1 BUGS

  Aquiring a lock within the same process always fails.

  Stale locks from abnormal termination are not detected.

=head2 FIFO

Locks are not necessarily obtained on a first come first serve basis.
Not only does this not seem fair to new processes trying to obtain a lock,
but it may cause a process starvation condition on heavily locked files.


=head2 DIRECTORIES

Locks cannot be obtained on directory nodes, nor can a directory node be
uncached with the uncache routine because hard links do not work with
directory nodes.  Some other algorithm might be used to uncache a
directory, but I am unaware of the best way to do it.  The biggest use I
can see would be to avoid NFS cache of directory modified and last accessed
timestamps.

=head1 INSTALL

Download and extract tarball before running
these commands in its base directory:

  perl Makefile.PL
  make
  make test
  make install

For RPM installation, download tarball before
running these commands in your _topdir:

  rpm -ta SOURCES/File-NFSLock-*.tar.gz
  rpm -ih RPMS/noarch/perl-File-NFSLock-*.rpm

=head1 AUTHORS

Paul T Seamons (paul@seamons.com) - Performed majority of the
programming with copious amounts of input from Rob Brown.

Rob B Brown (bbb@cpan.org) - In addition to helping in the
programming, Rob Brown provided most of the core testing to make sure
implementation worked properly.

Also Mark Overmeer (mark@overmeer.net) - Author of Mail::Box::Locker,
from which some key concepts for File::NFSLock were taken.

Also Kevin Johnson (kjj@pobox.com) - Author of Mail::Folder::Maildir,
from which Mark Overmeer based Mail::Box::Locker.

=head1 COPYRIGHT

  Copyright (C) 2001, Paul T Seamons
                      paul@seamons.com
                      http://seamons.com/

                      Rob B Brown
                      bbb@cpan.org

  This package may be distributed under the terms of either the
  GNU General Public License
    or the
  Perl Artistic License

  All rights reserved.

=cut
