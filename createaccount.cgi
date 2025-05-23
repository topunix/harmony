#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

use 5.10.1;
use strict;
use warnings;

use lib qw(. lib local/lib/perl5);

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Token;

# Just in case someone already has an account, let them get the correct footer
# on an error message. The user is logged out just after the account is
# actually created.
my $user     = Bugzilla->login(LOGIN_OPTIONAL);
my $cgi      = Bugzilla->cgi;
my $template = Bugzilla->template;
my $vars     = {doc_section => 'myaccount.html'};

print $cgi->header();

$user->check_account_creation_enabled;
my $login = $cgi->param('login');

if (defined($login)) {

  # Check the hash token to make sure this user actually submitted
  # the create account form.
  my $token = $cgi->param('token');
  check_hash_token($token, ['create_account']);
  
  my $email = $cgi->param('email');
  $user->check_and_send_account_creation_confirmation($login, $email);
  $vars->{'login'} = $login;
  $vars->{'email'} = $email;

  $template->process("account/created.html.tmpl", $vars)
    || ThrowTemplateError($template->error());
  exit;
}

# Show the standard "would you like to create an account?" form.
$template->process("account/create.html.tmpl", $vars)
  || ThrowTemplateError($template->error());
