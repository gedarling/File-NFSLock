# Lock Test with fatal error (die)

use Test;
use File::NFSLock;
use Fcntl qw(O_CREAT O_RDWR O_RDONLY O_TRUNC LOCK_EX);

$| = 1; # Buffer must be autoflushed because of fork() below.
plan tests => 9;

my $datafile = "testfile.dat";

# Wipe lock file in case it exists
unlink ("$datafile$File::NFSLock::LOCK_EXTENSION");

# Create a blank file
sysopen ( FH, $datafile, O_CREAT | O_RDWR | O_TRUNC );
close (FH);
# test 1
ok (-e $datafile && !-s _);


# test 2
ok (pipe(RD1,WR1)); # Connected pipe for child1

my $pid = fork;
if (!$pid) {
  # Child #1 process
  # Obtain exclusive lock
  my $lock = new File::NFSLock {
    file => $datafile,
    lock_type => LOCK_EX,
  };
  print WR1 !!$lock; # Send boolean success status down pipe
  close(WR1); # Signal to parent that the Blocking lock is done
  close(RD1);
  if ($lock) {
    sysopen(FH, $datafile, O_RDWR | O_TRUNC);
    # And then put a magic word into the file
    print FH "exclusive\n";
    close FH;
    open(STDERR,">/dev/null");
    die "I will die while lock is still aquired";
  }
  die "Lock failed!";
}

# test 3
ok 1; # Fork successful
close (WR1);
# Waiting for child1 to finish its lock status
my $child1_lock = <RD1>;
close (RD1);
# Report status of the child1_lock.
# It should have been successful
# test 4
ok ($child1_lock);

# Clear the zombie
# test 5
ok (wait);

# test 6
ok (pipe(RD2,WR2)); # Connected pipe for child2
if (!fork) {
  # The last lock died, so this should aquire fine.
  my $lock = new File::NFSLock {
    file => $datafile,
    lock_type => LOCK_EX,
    blocking_timeout => 10,
  };
  if ($lock) {
    sysopen(FH, $datafile, O_RDWR | O_TRUNC);
    # Immediately put the magic word into the file
    print FH "lock2\n";
    truncate (FH, tell FH);
    close FH;
  }
  print WR2 !!$lock; # Send boolean success status down pipe
  close(WR2); # Signal to parent that the Blocking lock is done
  close(RD2);
  exit; # Release this new lock
}
# test 7
ok 1; # Fork successful
close (WR2);

# Waiting for child2 to finish its lock status
my $child2_lock = <RD2>;
close (RD2);
# Report status of the child2_lock.
# This should have been successful.
# test 8
ok ($child2_lock);

# Load up whatever the file says now
sysopen(FH, $datafile, O_RDONLY);

$_ = <FH>;
# test 9
ok /lock2/;
close FH;

# Wipe the temporary file
unlink $datafile;
