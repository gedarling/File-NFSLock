# -*- perl -*-
#
#  File::NFSLock - bdpO - NFS compatible (safe) locking utility
#  
#  $Id: NFSLock.pm,v 1.14 2001/07/31 18:23:17 pauls Exp $
#  
#  Copyright (C) 2001, Paul T Seamons
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
use vars qw(@ISA @EXPORT_OK $VERSION $TYPES $extended $LOCK_EXTENSION $errstr);

@ISA = qw(Exporter);
@EXPORT_OK = qw(uncache);

$VERSION = '1.10';

### hash of types
$TYPES = {
  BLOCKING    => 'BL',
  BL          => 'BL',
  EXCLUSIVE   => 'BL',
  EX          => 'BL',
  NONBLOCKING => 'NB',
  NB          => 'NB',
  SHARED      => 'SH',
  SH          => 'SH',
};
$extended = undef; # are Fcntl constants loaded ?
$LOCK_EXTENSION = '.NFSLock'; # customizable extension

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
    $self->{blocking_timeout}   = @_ ? shift : undef;
    $self->{stale_lock_timeout} = @_ ? shift : undef;
  }
  $self->{blocking_timeout}   ||= 0;
  $self->{stale_lock_timeout} ||= 0;

  ### if passed a numerical lock type, load contants
  if( $self->{lock_type} =~ /^\d+/ && ! $extended ){
    $extended = 1;
    require "Fcntl.pm";
    $TYPES->{ Fcntl::LOCK_SH() } = 'SH';
    $TYPES->{ Fcntl::LOCK_EX() } = 'BL';
    $TYPES->{ Fcntl::LOCK_NB() } = 'NB';
  }

  ### quick usage check
  die $errstr = "Usage: my \$f = File::NFSLock->new('/pathtofile/file',\n"
    ."'BLOCKING|EXCLUSIVE|NONBLOCKING|SHARED', [blocking_timeout, stale_lock_timeout]);\n"
      ."(You passed \"$self->{file}\" and \"$self->{lock_type}\")"
        unless length($self->{file}) && exists $TYPES->{ $self->{lock_type} };
  $self->{lock_type} = $TYPES->{ $self->{lock_type} };

  die $errstr = "Shared Locks are not yet implemented (but soon)"
    if $self->{lock_type} eq 'SH';
  
  ### set some utility files
  $self->{local_file} = local_file( $self->{file} );
  $self->{lock_file}  = $self->{file} . $LOCK_EXTENSION;

  ### open a local temporary file
  open_local_file( $self->{local_file} )
    or return undef;

  ### nonblocking lock (return undef on failure)
  if( $self->{lock_type} eq 'NB' ){
    do_lock( $self->{lock_file}, $self->{local_file}, $self->{stale_lock_timeout} )
      or do { $errstr = "Couldn't get a lock on a NONBLOCKING lock"; return undef; };

  ### blocking lock, wait until it's done
  }else{
    do_lock_blocking( $self->{lock_file}, $self->{local_file}, $self->{blocking_timeout}, $self->{stale_lock_timeout} )
      or return undef;

  }

  ### clear up the NFS cache
  uncache( $self->{file} );

  ### only do a bless object if everything is good till now
  bless $self, $class;
  return $self;
}

sub unlock ($) {
  shift()->DESTROY();
}

sub DESTROY {
  my $self = shift;
  unlink( $self->{local_file} ) if -e $self->{local_file};
  do_unlock( $self->{lock_file} );
}

###----------------------------------------------------------------###

# concepts for these routines were taken from Mail::Box which
# took the concepts from Mail::Folder


sub local_file ($) {
  my $lock_file = shift;
  return $lock_file .'.tmp.'. time()%10000 .'.'. $$ .'.'. int(rand()*10000);
}

sub open_local_file ($) {
  $errstr = undef;
  my $local_file = shift;
  open (_LOCK,">>$local_file") or do { $errstr = "Couldn't open \"$local_file\" [$!]"; return undef; };
  print _LOCK "Pid [$$]\nHost [$ENV{HOSTNAME}]\nFile [$local_file]\n"; # trace information
  close(_LOCK);
  return 1;
}

sub do_lock {
  $errstr = undef;
  my $lock_file     = shift;
  my $local_file    = shift;
  my $stale_timeout = shift || 0;
  my $recurse       = shift || 0;

  ### try a hard link
  link( $local_file, $lock_file);

  ### did it work (two files pointing to local_file)
  my $success = ( -e $local_file && (stat($local_file))[3] == 2 );
  unlink $local_file;

  ### remove an old lockfile if it is older than the stale_timeout
  if( ! $success && $stale_timeout > 0 ){
    if( !-e $lock_file || time() - (stat($lock_file))[9] > $stale_timeout ){ # check mtime
      if( ! unlink($lock_file) ){
        $errstr = "Can't unlink stale lock file \"$lock_file\" [$!]";
        return undef;
      }elsif( ++$recurse >= 10 ){
        $errstr = "Max retries reached trying to remove stale lockfile";
        return undef;
      }else{
        return do_lock( $lock_file, $local_file, $stale_timeout,$recurse );
      }
    }
  }

  return $success;
}

sub do_lock_blocking {
  $errstr = undef;
  my $lock_file     = shift;
  my $local_file    = shift;
  my $timeout       = shift;
  my $stale_timeout = shift || 0;
  my $start_time = $timeout ? time() : 0;

  while( ! do_lock( $lock_file, $local_file, $stale_timeout ) ){

    ### wait a moment
    sleep(1);

    ### but don't wait past the time out
    if( $timeout && (time() - $start_time) > $timeout ){
      $errstr = "Timed out waiting for blocking lock";
      return undef;
    }

    ### reopen the file
    open_local_file( $local_file ) or return undef;
  }

  return 1;
}

sub do_unlock ($) {
  my $lock_file = shift;
  return unlink($lock_file);
}

sub uncache ($;$) {
  shift() if ref($_[0]);  # allow as method call
  my $file       = shift;
  my $local_file = local_file( $file );

  ### hard link to the actual file which will bring it up to date
  return ( link($file, $local_file) && unlink($local_file) );
}

1;


=head1 NAME 

File::NFSLock - perl module to do NFS (or not) locking

=head1 SYNOPSIS

  use File::NFSLock (uncache);

  my $file = "somefile";

  ### set up a lock - lasts until object looses scope
  if( defined(my $lock = File::NFSLock->new({
    file      => $file,
    lock_type => "NONBLOCKING"
    blocking_timeout   => 10,      # 10 sec
    stale_lock_timeout => 30 * 60, # 60 min
    })) ){
    
    ### OR
    ### my $lock = File::NFSLock->new($file,"NONBLOCKING",10,30*60)

    
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
  Fcntl::LOCK_EX() (BLOCKING)
  Fcntl::LOCK_NB() (NONBLOCKING)
  Fcntl::LOCK_SH() (SHARED)

Lock type determines whether the lock will be blocking, non blocking,
or shared.  Blocking locks will wait until other locks are removed
before the process continues.  Non blocking locks will return undef if
another process currently has the lock.  Shared will allow other
process to do a shared lock at the same time (shared is not yet
implemented).

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
now in a global variable $File::NFSLock::LOCK_EXTENSION that may be changed to
suit other purposes (such as compatibility in mail systems).

=head1 TODO

Features yet to be implemented...

=over 4

=item SHARED locks

Need to allow for shared locking.  This will allow for safe
reading on files.  Underway.

=item Tests

Improve the test suite.

=back


=head1 AUTHORS

Paul T Seamons (paul@seamons.com) - Performed majority of the
programming with copious amounts of input from Rob Brown.

Rob B Brown (rob@roobik.com) - In addition to helping in the
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
                      rob@roobik.com
  
  This package may be distributed under the terms of either the
  GNU General Public License 
    or the
  Perl Artistic License

  All rights reserved.

=cut
