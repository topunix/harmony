#!/usr/bin/env perl
use 5.10.1;
use strict;
use warnings;
use lib qw(/app /app/local/lib/perl5);
use autodie qw(:all);

use Bugzilla::Install::Localconfig ();
use Bugzilla::Install::Util qw(install_string);
use Bugzilla::Test::Util qw(create_user);
use Bugzilla::DaemonControl qw(
  run_cereal_and_httpd
  run_cereal_and_jobqueue
  assert_httpd assert_database assert_selenium
  on_finish on_exception
);

use DBI;
use Data::Dumper;
use English qw(-no_match_vars $EUID);
use File::Copy::Recursive qw(dircopy);
use Getopt::Long qw(:config gnu_getopt);
use IO::Async::Loop;
use IO::Async::Process;
use IO::Async::Signal;
use IO::Async::Timer::Periodic;
use LWP::Simple qw(get);
use Path::Tiny;
use POSIX qw(WEXITSTATUS setsid);
use Sys::Hostname;
use User::pwent;

BEGIN {
  STDOUT->autoflush(1);
  STDERR->autoflush(1);
}

use constant CI => $ENV{CI};

my $cmd  = shift @ARGV;
print "cmd = $cmd\n";
my $opts = __PACKAGE__->can("opt_$cmd") // sub {@ARGV};
my $func = __PACKAGE__->can("cmd_$cmd") // sub {
  check_data_dir();
  wait_for_db();
  run($cmd, @_);
};

fix_path();
check_user();
check_env(qw(
    LOCALCONFIG_ENV
    BMO_db_host
    BMO_db_name
    BMO_db_user
    BMO_db_pass
    BMO_memcached_namespace
    BMO_memcached_servers
    BMO_urlbase
    ));

if ($ENV{BMO_urlbase} eq 'AUTOMATIC') {
  my $urlbase = sprintf 'http://%s:%d', hostname(), $ENV{PORT};
  $ENV{BZ_BASE_URL} = $ENV{BMO_urlbase} = $urlbase . '/';
  my $file = path($ENV{BZ_QA_CONF_FILE});
  my $data = $file->slurp_utf8;
  $data =~ s{http://bmo.test/?}{$urlbase}g;
  $file->spew_utf8( $data );
}

$func->($opts->());

sub cmd_demo {
  unless (-f '/app/data/params') {
    cmd_load_test_data();
    check_env(qw(
        PHABRICATOR_BOT_LOGIN
        PHABRICATOR_BOT_PASSWORD
        PHABRICATOR_BOT_API_KEY
        CONDUIT_USER_LOGIN
        CONDUIT_USER_PASSWORD
        CONDUIT_USER_API_KEY
        ));
    run('perl', 'scripts/generate_conduit_data.pl');
  }
  cmd_httpd();
}

sub cmd_httpd {
  check_data_dir();
  wait_for_db();

  my $httpd_exit_f = run_cereal_and_httpd();
  assert_httpd()->get();
  exit $httpd_exit_f->get();
}

sub cmd_jobqueue {
  my (@args) = @_;
  check_data_dir();
  wait_for_db();
  exit run_cereal_and_jobqueue(@args)->get;
}

sub cmd_selenium_dev {
  cmd_load_test_data();
  check_data_dir();
  copy_qa_extension();
  mkdir('/app/artifacts');

  assert_database->get();
  my $httpd_exit_f = run_cereal_and_httpd('-DACCESS_LOGS');
  assert_httpd()->get;
  exit $httpd_exit_f->get;
}

sub cmd_dev_httpd {
  my $have_params = -f "/app/data/params";
  assert_database->get();

  run('perl', 'checksetup.pl', '--no-template', $ENV{BZ_ANSWERS_FILE});
  if (not $have_params) {
    run(
      'perl', 'scripts/generate_bmo_data.pl',
      '--param' => 'use_mailer_queue=0',
      'admin_bmo_test'
    );
  }

  require Bugzilla;
  my $answers = Bugzilla->installation_answers($ENV{BZ_ANSWERS_FILE});
  my $BZ_URLBASE = $::ENV{'BMO_urlbase'};
  my $LOGIN_USER = "Admin user: $answers->{'ADMIN_LOGIN_NAME'}";
  my $LOGIN_PASS = "Admin password: $answers->{'ADMIN_PASSWORD'}";
  print <<EOF;
#########################################
##                                     ##
##  Your Bugzilla installation should  ##
##         now be reachable at:        ##
##                                     ##
EOF
printf "##%s%s%s##\n", ' ' x int((37 - length($BZ_URLBASE)) / 2), $BZ_URLBASE, ' ' x (int((37 - length($BZ_URLBASE)) / 2) + (1 - length($BZ_URLBASE)%2));
  print <<EOF;
##                                     ##
EOF
printf "##%s%s%s##\n", ' ' x int((37 - length($LOGIN_USER)) / 2), $LOGIN_USER, ' ' x (int((37 - length($LOGIN_USER)) / 2) + (1 - length($LOGIN_USER)%2));
printf "##%s%s%s##\n", ' ' x int((37 - length($LOGIN_PASS)) / 2), $LOGIN_PASS, ' ' x (int((37 - length($LOGIN_PASS)) / 2) + (1 - length($LOGIN_PASS)%2));
print <<EOF;
##                                     ##
##   user/password only valid if you   ##
##    haven't already changed them.    ##
##                                     ##
#########################################
EOF
  my $httpd_exit_f = run_cereal_and_httpd('-DACCESS_LOGS');
  assert_httpd()->get;
  exit $httpd_exit_f->get;
}

sub cmd_checksetup {
  check_data_dir();
  wait_for_db();
  run('perl', 'checksetup.pl', '--no-template', '--no-permissions');
}

sub cmd_load_test_data {
  wait_for_db();

  die 'BZ_QA_ANSWERS_FILE is not set' unless $ENV{BZ_QA_ANSWERS_FILE};
  run('perl', 'checksetup.pl', '--no-template', $ENV{BZ_QA_ANSWERS_FILE});

  run(
    'perl',        'scripts/generate_bmo_data.pl',
    '--param',     'use_mailer_queue=0'
  );

  if ($ENV{BZ_QA_CONFIG}) {
    chdir '/app/qa/config';
    say 'chdir(/app/qa/config)';
    run('perl', 'generate_test_data.pl');
    chdir '/app';
  }
}

sub cmd_push_data {
  run('perl', 'scripts/build-bmo-push-data.pl');
}

sub cmd_test_sanity {
  my @tests = @_;
  run('prove', '-I/app', '-I/app/local/lib/perl5', '-qf', @tests);
}

sub cmd_test_webservices {
  cmd_test_qa('{webservice,rest}_*.t');
}

sub cmd_test_selenium {
  cmd_test_qa('test_*.t');
}

sub cmd_test_qa {
  my $test_files = shift;
  $ENV{HTTP_BACKEND} = 'simple';

  cmd_load_test_data();
  check_data_dir();
  mkdir('/app/artifacts');

  assert_database()->get;
  my $httpd_exit_f = run_cereal_and_httpd('-DHTTPD_IN_SUBDIR', '-DACCESS_LOGS');
  my $prove_exit_f = run_prove(
    prove_cmd => [
      'prove', '-qf', '-I/app', '-I/app/local/lib/perl5',
      sub { glob $test_files },
    ],
    prove_dir => '/app/qa/t',
  );
  exit Future->wait_any($prove_exit_f, $httpd_exit_f)->get;
}

sub cmd_shell { run('bash', '-l'); }

sub cmd_prove {
  my (@args) = @_;
  run('prove', '-I/app', '-I/app/local/lib/perl5', @args);
}

sub cmd_version { run('cat', '/app/version.json'); }

sub cmd_test_bmo {
  my (@prove_args) = @_;
  $ENV{HTTP_BACKEND} = 'simple';

  cmd_load_test_data();
  check_data_dir();

  assert_database()->get;
  assert_selenium('selenium')->get;
  $ENV{BZ_TEST_NEWBIE}      = 'newbie@mozilla.example';
  $ENV{BZ_TEST_NEWBIE_PASS} = 'captain.space.bagel.ROBOT!';
  create_user(
    $ENV{BZ_TEST_NEWBIE},
    $ENV{BZ_TEST_NEWBIE_PASS},
    realname => 'Newbie User'
  );

  $ENV{BZ_TEST_NEWBIE2}      = 'newbie2@mozilla.example';
  $ENV{BZ_TEST_NEWBIE2_PASS} = 'captain.space.pants.time.lord';

  my $httpd_exit_f = run_cereal_and_httpd('-DACCESS_LOGS');
  my $prove_exit_f = run_prove(
    prove_cmd => ['prove', '-I/app', '-I/app/local/lib/perl5', @prove_args],
  );

  exit Future->wait_any($prove_exit_f, $httpd_exit_f)->get;
}

sub run_prove {
  my (%param) = @_;

  my $prove_cmd = $param{prove_cmd};
  my $prove_dir = $param{prove_dir};
  assert_httpd()->then(sub {
    my $loop = IO::Async::Loop->new;
    $loop->connect(socktype => 'stream', host => 'localhost', service => 5880,)
      ->then(sub {
      my $socket       = shift;
      my $prove_exit_f = $loop->new_future;
      my $prove        = IO::Async::Process->new(
        code => sub {
          chdir $prove_dir if $prove_dir;
          my @cmd = (map { ref $_ eq 'CODE' ? $_->() : $_ } @$prove_cmd);
          warn "run @cmd\n";
          exec @cmd;
        },
        setup        => [stdin => ['close'], stdout => ['dup', $socket],],
        on_finish    => on_finish($prove_exit_f),
        on_exception => on_exception('prove', $prove_exit_f),
      );
      $prove_exit_f->on_cancel(sub { $prove->kill('TERM') });
      $loop->add($prove);
      return $prove_exit_f;
      });
  });
}

sub copy_qa_extension {
  say 'copying the QA extension...';
  dircopy('/app/qa/extensions/QA', '/app/extensions/QA');
}

sub wait_for_db {
  assert_database()->get;
}

sub check_user {
  die 'Effective UID must be 10001!' unless $EUID == 10_001;
  my $user = getpwuid($EUID)->name;
  die "Name of EUID must be app, not $user" unless $user eq 'app';
}

sub check_data_dir {
  die "/app/data must be writable by user 'app' (id: $EUID)"
    unless -w '/app/data';
  die '/app/data/params must exist' unless -f '/app/data/params';
}

sub check_env {
  my (@require_env) = @_;
  my @missing_env = grep { not exists $ENV{$_} } @require_env;
  if (@missing_env) {
    die 'Missing required environmental variables: ', join(', ', @missing_env),
      "\n";
  }
}

sub fix_path {
  $ENV{PATH} = "/app/local/bin:$ENV{PATH}";
}

sub run {
  my (@cmd) = @_;
  say "+ @cmd";
  my $rv = system @cmd;
  if ($rv != 0) {
    exit 1;
  }
}
