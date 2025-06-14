# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::User;

use 5.10.1;
use strict;
use warnings;

use Bugzilla::Error;
use Bugzilla::Util;
use Bugzilla::Constants;
use Bugzilla::Search::Recent;
use Bugzilla::User::Setting;
use Bugzilla::User::Email;
use Bugzilla::Product;
use Bugzilla::Classification;
use Bugzilla::Field;
use Bugzilla::Group;
use Bugzilla::Hook;
use Bugzilla::BugUserLastVisit;


use DateTime::TimeZone;
use List::Util qw(max);
use List::MoreUtils qw(any);
use Scalar::Util qw(blessed);
use Storable qw(dclone);
use URI;
use URI::QueryParam;
use Role::Tiny::With;

use base qw(Bugzilla::Object Exporter);

with 'Bugzilla::Role::Storable', 'Bugzilla::Role::FlattenToHash';

@Bugzilla::User::EXPORT = qw(is_available_username
  login_to_id user_id_to_login
  USER_MATCH_MULTIPLE USER_MATCH_FAILED USER_MATCH_SUCCESS
  MATCH_SKIP_CONFIRM
);

#####################################################################
# Constants
#####################################################################

use constant USER_MATCH_MULTIPLE => -1;
use constant USER_MATCH_FAILED   => 0;
use constant USER_MATCH_SUCCESS  => 1;

use constant MATCH_SKIP_CONFIRM => 1;

use constant DEFAULT_USER => {
  'userid'         => 0,
  'realname'       => '',
  'login_name'     => '',
  'showmybugslink' => 0,
  'disabledtext'   => '',
  'disable_mail'   => 0,
  'is_enabled'     => 1,
};

use constant DB_TABLE => 'profiles';

# XXX Note that Bugzilla::User->name does not return the same thing
# that you passed in for "name" to new(). That's because historically
# Bugzilla::User used "name" for the realname field. This should be
# fixed one day.
sub DB_COLUMNS {
  my $dbh = Bugzilla->dbh;
  return (
    'profiles.userid',
    'profiles.login_name',
    'profiles.realname',
    'profiles.mybugslink AS showmybugslink',
    'profiles.disabledtext',
    'profiles.disable_mail',
    'profiles.extern_id',
    'profiles.is_enabled',
    $dbh->sql_date_format('last_seen_date', '%Y-%m-%d') . ' AS last_seen_date',
    'profiles.password_change_required',
    'profiles.password_change_reason',
    'profiles.mfa',
    'profiles.mfa_required_date',
    'profiles.nickname',
    'profiles.bounce_count'
    ),
    ;
}

use constant NAME_FIELD => 'login_name';
use constant ID_FIELD   => 'userid';
use constant LIST_ORDER => NAME_FIELD;

use constant VALIDATORS => {
  cryptpassword            => \&_check_password,
  disable_mail             => \&_check_disable_mail,
  disabledtext             => \&_check_disabledtext,
  login_name               => \&check_login_name_for_creation,
  realname                 => \&_check_realname,
  nickname                 => \&_check_realname,
  extern_id                => \&_check_extern_id,
  is_enabled               => \&_check_is_enabled,
  password_change_required => \&Bugzilla::Object::check_boolean,
  password_change_reason   => \&_check_password_change_reason,
  mfa                      => \&_check_mfa,
  bounce_count             => \&_check_numeric,
};

sub UPDATE_COLUMNS {
  my $self = shift;
  my @cols = qw(
    disable_mail
    disabledtext
    login_name
    realname
    extern_id
    is_enabled
    password_change_required
    password_change_reason
    mfa
    mfa_required_date
    nickname
    bounce_count
  );
  push(@cols, 'cryptpassword') if exists $self->{cryptpassword};
  return @cols;
}

use constant VALIDATOR_DEPENDENCIES => {
  is_enabled             => ['disabledtext'],
  password_change_reason => ['password_change_required'],
};

use constant EXTRA_REQUIRED_FIELDS => qw(is_enabled);

################################################################################
# Functions
################################################################################

sub new {
  my $invocant = shift;
  my $class    = ref($invocant) || $invocant;
  my ($param)  = @_;

  my $user = {%{DEFAULT_USER()}};
  bless($user, $class);
  return $user unless $param;

  if (ref($param) eq 'HASH') {
    if (defined $param->{extern_id}) {
      $param = {condition => 'extern_id = ?', values => [$param->{extern_id}]};
      $_[0] = $param;
    }
    elsif (exists $param->{name}) {
      my $email = $param->{name};
      
      my $user_id = Bugzilla::User::Email->get_user_by_email($email);
      if ($user_id) {
        $param->{id} = $user_id;
        delete $param->{name};
      }
    }
  }

  $user = $class->SUPER::new(@_);

  # MySQL considers some non-ascii characters such as umlauts to equal
  # ascii characters returning a user when it should not.
  if ($user && ref $param eq 'HASH' && exists $param->{name}) {
    my $login = $param->{name};
    if (lc $login ne lc $user->login) {
      $user = undef;
    }
  }

  return $user;
}

sub super_user {
  my $invocant = shift;
  my $class    = ref($invocant) || $invocant;
  my ($param)  = @_;

  my $user = {%{DEFAULT_USER()}};
  $user->{groups}       = [Bugzilla::Group->get_all];
  $user->{bless_groups} = [Bugzilla::Group->get_all];
  bless $user, $class;
  return $user;
}

sub _update_groups {
  my $self          = shift;
  my $group_changes = shift;
  my $changes       = shift;
  my $dbh           = Bugzilla->dbh;
  my $user          = Bugzilla->user;

  # Update group settings.
  my $sth_add_mapping = $dbh->prepare(
    qq{INSERT INTO user_group_map (
                  user_id, group_id, isbless, grant_type
                 ) VALUES (
                  ?, ?, ?, ?
                 )
          }
  );
  my $sth_remove_mapping = $dbh->prepare(
    qq{DELETE FROM user_group_map
            WHERE user_id = ?
              AND group_id = ?
              AND isbless = ?
              AND grant_type = ?
          }
  );

  foreach my $is_bless (keys %$group_changes) {
    my ($removed, $added) = @{$group_changes->{$is_bless}};

    foreach my $group (@$removed) {
      $sth_remove_mapping->execute($self->id, $group->id, $is_bless, GRANT_DIRECT);
      Bugzilla->audit(sprintf(
        '%s <%s> removed group %s from %s',
        $user->login, remote_ip(), $group->name, $self->login
      ));
    }
    foreach my $group (@$added) {
      $sth_add_mapping->execute($self->id, $group->id, $is_bless, GRANT_DIRECT);
      Bugzilla->audit(sprintf(
        '%s <%s> added group %s to %s',
        $user->login, remote_ip(), $group->name, $self->login
      ));
    }

    if (!$is_bless) {
      my $query = qq{
                INSERT INTO profiles_activity
                    (userid, who, profiles_when, fieldid, oldvalue, newvalue)
                VALUES ( ?, ?, now(), ?, ?, ?)
            };

      $dbh->do(
        $query, undef, $self->id, $user->id,
        get_field_id('bug_group'),
        join(', ', map { $_->name } @$removed),
        join(', ', map { $_->name } @$added)
      );
    }
    else {
      # XXX: should create profiles_activity entries for blesser changes.
    }

    Bugzilla->memcached->clear_config({key => 'user_groups.' . $self->id});

    my $type = $is_bless ? 'bless_groups' : 'groups';
    $changes->{$type} = [[map { $_->name } @$removed], [map { $_->name } @$added],];
  }
}

sub update {
  my $self    = shift;
  my $options = shift;

  my $group_changes = delete $self->{_group_changes};

  my $changes = $self->SUPER::update(@_);
  my $dbh     = Bugzilla->dbh;
  $self->_update_groups($group_changes, $changes);

  if (exists $changes->{login_name}) {

    # Delete all the tokens related to the userid
    $dbh->do('DELETE FROM tokens WHERE userid = ?', undef, $self->id)
      unless $options->{keep_tokens};

    # And rederive regex groups
    $self->derive_regexp_groups();
  }

  if (exists $changes->{mfa} && $self->mfa eq '') {
    if (Bugzilla->user->id != $self->id) {
      Bugzilla->audit(
        sprintf('%s disabled 2FA for %s', Bugzilla->user->login, $self->login));
    }
    $dbh->do("DELETE FROM profile_mfa WHERE user_id = ?", undef, $self->id);
  }

  # Logout the user if necessary.
  Bugzilla->logout_user($self)
    if (
    !$options->{keep_session}
    && ( exists $changes->{login_name}
      || exists $changes->{disabledtext}
      || exists $changes->{cryptpassword})
    );

  # XXX Can update profiles_activity here as soon as it understands
  #     field names like login_name.

  return $changes;
}

################################################################################
# Validators
################################################################################

sub _check_disable_mail {
  my ($invocant, $value) = @_;
  return 1 if ref($invocant) && !$invocant->is_enabled;
  return $value ? 1 : 0;
}

sub _check_disabledtext { return trim($_[1]) || ''; }

# Check whether the extern_id is unique.
sub _check_extern_id {
  my ($invocant, $extern_id) = @_;
  $extern_id = trim($extern_id);
  return undef unless defined($extern_id) && $extern_id ne "";
  if (!ref($invocant) || $invocant->extern_id ne $extern_id) {
    my $existing_login = $invocant->new({extern_id => $extern_id});
    if ($existing_login) {
      ThrowUserError('extern_id_exists',
        {extern_id => $extern_id, existing_login_name => $existing_login->login});
    }
  }
  return $extern_id;
}

# This is public since createaccount.cgi needs to use it before issuing
# a token for account creation.
sub check_login_name_for_creation {
  my ($invocant, $name) = @_;
  $name = trim($name);
  $name || ThrowUserError('user_login_required');

  # No whitespace
  $name !~ /\s/ || ThrowUserError('login_illegal_character');

  # We set the max length to 127 to ensure logins aren't truncated when
  # inserted into the tokens.eventdata field.
  length($name) <= 127 or ThrowUserError('login_too_long');

  # Check the name if it's a new user, or if we're changing the name.
  if (!ref($invocant) || $invocant->login ne $name) {
    is_available_username($name)
      || ThrowUserError('account_exists', {login => $name});
  }

  return $name;
}


sub _check_password {
  my ($self, $pass) = @_;

  # If the password is '*', do not encrypt it or validate it further--we
  # are creating a user who should not be able to log in using DB
  # authentication.
  return $pass if $pass eq '*';

  Bugzilla->assert_password_is_secure($pass);
  my $cryptpassword = bz_crypt($pass);
  return $cryptpassword;
}

sub _check_realname { return trim($_[1]) || ''; }

sub _check_is_enabled {
  my ($invocant, $is_enabled, undef, $params) = @_;

  # is_enabled is set automatically on creation depending on whether
  # disabledtext is empty (enabled) or not empty (disabled).
  # When updating the user, is_enabled is set by calling set_disabledtext().
  # Any value passed into this validator is ignored.
  my $disabledtext
    = ref($invocant) ? $invocant->disabledtext : $params->{disabledtext};
  return $disabledtext ? 0 : 1;
}

sub _check_password_change_reason {
  my ($self, $value) = @_;
  return $self->password_change_required ? trim($_[1]) || '' : '';
}

sub _check_mfa {
  my ($self, $provider) = @_;
  $provider = lc($provider // '');
  return 'TOTP' if $provider eq 'totp';
  return 'Duo'  if $provider eq 'duo';

  # you must be member of the bz_can_disable_mfa group to disable mfa for
  # other accounts.
  if ($provider eq '') {
    my $user = Bugzilla->user;
    if ($user->id != $self->id && !$user->in_group('bz_can_disable_mfa')) {
      ThrowUserError('mfa_disable_denied');
    }
  }

  return '';
}

sub _check_numeric {
  my ($self, $value) = (@_);
  if ($value !~ /^[0-9]+$/) {
    ThrowCodeError('param_must_be_numeric',
        {param => $value, function => 'Bugzilla::User::_check_numeric'});
    return "must be a numeric value";
  }
  return $value;
}

################################################################################
# Mutators
################################################################################

sub set_disable_mail  { $_[0]->set('disable_mail', $_[1]); }
sub set_email_enabled { $_[0]->set('disable_mail', !$_[1]); }
sub set_extern_id     { $_[0]->set('extern_id',    $_[1]); }

sub set_password_change_required {
  $_[0]->set('password_change_required', $_[1]);
}
sub set_password_change_reason { $_[0]->set('password_change_reason', $_[1]); }

sub set_login {
  my ($self, $login) = @_;
  $self->set('login_name', $login);
  delete $self->{identity};
  delete $self->{nick};
}

sub _generate_nickname {
  my ($name, $login, $id) = @_;
  my ($nick) = extract_nicks($name);
  if (!$nick) {
    $nick = "";
  }
  my ($count)
    = Bugzilla->dbh->selectrow_array(
    'SELECT COUNT(*) FROM profiles WHERE nickname = ? AND userid != ?',
    undef, $nick, $id);
  if ($count) {
    $nick = "";
  }
  return $nick;
}

sub set_email {
  my ($self, $email) = @_;
  # Create a user email account
  my $email_data = {
    user_id          => $self->id,
    email            => $email,
    is_primary_email => 1
  };

  my $user_email = Bugzilla::User::Email->create($email_data);
}


sub set_name {
  my ($self, $name) = @_;
  $self->set('realname', $name);
  delete $self->{identity};
  $self->set('nickname', _generate_nickname($name, $self->login, $self->id));
}

sub set_nick {
  my ($self, $nick) = @_;
  $self->set('nickname', $nick);
}

sub set_password {
  my ($self, $password) = @_;
  # Reactivate account if user was disabled due to inactivity
  if ($self->password_change_reason eq 'Inactive Account') {
    $self->set_disabledtext('');
    $self->set_disable_mail(0);
  }
  $self->set('cryptpassword',            $password);
  $self->set('password_change_required', 0);
  $self->set('password_change_reason',   '');

}

sub set_disabledtext {
  my ($self, $text) = @_;
  $self->set('disabledtext', $text);
  $self->set('is_enabled', trim($text) eq '' ? 0 : 1);
  $self->set('disable_mail', 1) if !$self->is_enabled;
}

sub set_mfa {
  my ($self, $value) = @_;
  $self->set('mfa', $value);
  delete $self->{mfa_provider};
}

sub set_mfa_required_date {
  my ($self, $value) = @_;
  $self->set('mfa_required_date', $value);
}

sub set_groups {
  my $self = shift;
  $self->_set_groups(GROUP_MEMBERSHIP, @_);
}

sub set_bless_groups {
  my $self = shift;

  # The person making the change needs to be in the editusers group
  Bugzilla->user->in_group('editusers') || ThrowUserError(
    "auth_failure",
    {
      group  => "editusers",
      reason => "cant_bless",
      action => "edit",
      object => "users"
    }
  );

  $self->_set_groups(GROUP_BLESS, @_);
}

sub _set_groups {
  my $self     = shift;
  my $is_bless = shift;
  my $changes  = shift;
  my $dbh      = Bugzilla->dbh;

  use Data::Dumper;

  # The person making the change is $user, $self is the person being changed
  my $user = Bugzilla->user;

  # Input is a hash of arrays. Key is 'set', 'add' or 'remove'. The array
  # is a list of group ids and/or names.

  # First turn the arrays into group objects.
  $changes = $self->_set_groups_to_object($changes);

  # Get a list of the groups the user currently is a member of
  my $ids = $dbh->selectcol_arrayref(
    q{SELECT DISTINCT group_id
            FROM user_group_map
           WHERE user_id = ? AND isbless = ? AND grant_type = ?}, undef, $self->id,
    $is_bless, GRANT_DIRECT
  );

  my $current_groups = Bugzilla::Group->new_from_list($ids);
  my $new_groups     = dclone($current_groups);

  # Record the changes
  if (exists $changes->{set}) {
    $new_groups = $changes->{set};

    # We need to check the user has bless rights on the existing groups
    # If they don't, then we need to add them back to new_groups
    foreach my $group (@$current_groups) {
      if (!$user->can_bless($group->id)) {
        push @$new_groups, $group unless grep { $_->id eq $group->id } @$new_groups;
      }
    }
  }
  else {
    foreach my $group (@{$changes->{remove} // []}) {
      @$new_groups = grep { $_->id ne $group->id } @$new_groups;
    }
    foreach my $group (@{$changes->{add} // []}) {
      push @$new_groups, $group unless grep { $_->id eq $group->id } @$new_groups;
    }
  }

  # Stash the changes, so self->update can actually make them
  my @diffs = diff_arrays($current_groups, $new_groups, 'id');
  if (scalar(@{$diffs[0]}) || scalar(@{$diffs[1]})) {
    $self->{_group_changes}{$is_bless} = \@diffs;
  }
}

sub _set_groups_to_object {
  my $self    = shift;
  my $changes = shift;
  my $user    = Bugzilla->user;

  foreach my $key (keys %$changes) {

    # Check we were given an array
    unless (ref($changes->{$key}) eq 'ARRAY') {
      ThrowCodeError('param_invalid', {param => $changes->{$key}, function => $key});
    }

    # Go through the array, and turn items into group objects
    my @groups = ();
    foreach my $value (@{$changes->{$key}}) {
      my $type = $value =~ /^\d+$/ ? 'id' : 'name';
      my $group = Bugzilla::Group->new({$type => $value});

      if (!$group || !$user->can_bless($group->id)) {
        ThrowUserError('auth_failure',
          {group => $value, reason => 'cant_bless', action => 'edit', object => 'users'});
      }
      push @groups, $group;
    }
    $changes->{$key} = \@groups;
  }

  return $changes;
}

sub update_last_seen_date {
  my $self = shift;
  return unless $self->id;
  my $dbh  = Bugzilla->dbh;
  my $date = $dbh->selectrow_array(
    'SELECT ' . $dbh->sql_date_format('NOW()', '%Y-%m-%d'));

  if (!$self->last_seen_date or $date ne $self->last_seen_date) {
    $self->{last_seen_date} = $date;

    # We don't use the normal update() routine here as we only
    # want to update the last_seen_date column, not any other
    # pending changes
    $dbh->do("UPDATE profiles SET last_seen_date = ? WHERE userid = ?",
      undef, $date, $self->id);
    Bugzilla->memcached->clear({table => 'profiles', id => $self->id});
  }
}

################################################################################
# Methods
################################################################################

# Accessors for user attributes
sub name           { $_[0]->{realname}; }
sub login          { $_[0]->{login_name}; }
sub extern_id      { $_[0]->{extern_id}; }
sub email          { Bugzilla::User::Email->get_primary_email_of_user($_[0]->{userid}) || $_[0]->login;}
sub disabledtext   { $_[0]->{'disabledtext'}; }
sub is_enabled     { $_[0]->{'is_enabled'} ? 1 : 0; }
sub showmybugslink { $_[0]->{showmybugslink}; }
sub email_disabled { $_[0]->{disable_mail} || !$_[0]->{is_enabled}; }
sub email_enabled  { !$_[0]->email_disabled; }
sub last_seen_date { $_[0]->{last_seen_date}; }
sub password_change_required { $_[0]->{password_change_required}; }
sub password_change_reason   { $_[0]->{password_change_reason}; }

sub cryptpassword {
  my $self = shift;

  # We don't store it because we never want it in the object (we
  # don't want to accidentally dump even the hash somewhere).
  my ($pw)
    = Bugzilla->dbh->selectrow_array(
    'SELECT cryptpassword FROM profiles WHERE userid = ?',
    undef, $self->id);
  return $pw;
}

sub set_authorizer {
  my ($self, $authorizer) = @_;
  $self->{authorizer} = $authorizer;
}

sub authorizer {
  my ($self) = @_;
  if (!$self->{authorizer}) {
    require Bugzilla::Auth;
    $self->{authorizer} = new Bugzilla::Auth();
  }
  return $self->{authorizer};
}

sub mfa { $_[0]->{mfa} }

sub mfa_required_date {
  my $self = shift;
  return $self->{mfa_required_date}
    ? datetime_from($self->{mfa_required_date}, @_)
    : undef;
}

sub mfa_provider {
  my ($self) = @_;
  my $mfa = $self->{mfa} || return undef;
  return $self->{mfa_provider} if exists $self->{mfa_provider};
  require Bugzilla::MFA;
  $self->{mfa_provider} = Bugzilla::MFA->new_from($self, $mfa);
  return $self->{mfa_provider};
}


sub in_mfa_group {
  my $self = shift;
  return $self->{in_mfa_group} if exists $self->{in_mfa_group};

  my $mfa_group = Bugzilla->params->{mfa_group};
  return $self->{in_mfa_group} = ($mfa_group && $self->in_group($mfa_group));
}

sub name_or_login {
  my $self = shift;

  return $self->name || $self->login;
}

# Generate a string to identify the user by name + login if the user
# has a name or by login only if they don’t.
sub identity {
  my $self = shift;

  return "" unless $self->id;

  if (!defined $self->{identity}) {
    $self->{identity}
      = $self->name ? $self->name . " <" . $self->login . ">" : $self->login;
  }

  return $self->{identity};
}

sub nick {
  my $self = shift;

  return "" unless $self->id;
  return $self->{nickname} if $self->{nickname};
  return $self->{nick} //= (split(/@/, $self->login, 2))[0];
}

sub queries {
  my $self = shift;
  return $self->{queries} if defined $self->{queries};
  return [] unless $self->id;

  my $dbh = Bugzilla->dbh;
  my $query_ids
    = $dbh->selectcol_arrayref('SELECT id FROM namedqueries WHERE userid = ?',
    undef, $self->id);
  require Bugzilla::Search::Saved;
  $self->{queries} = Bugzilla::Search::Saved->new_from_list($query_ids);

  # We preload link_in_footer from here as this information is always requested.
  # This only works if the user object represents the current logged in user.
  Bugzilla::Search::Saved::preload($self->{queries})
    if $self->id == Bugzilla->user->id;

  return $self->{queries};
}

sub queries_subscribed {
  my $self = shift;
  return $self->{queries_subscribed} if defined $self->{queries_subscribed};
  return [] unless $self->id;

  # Exclude the user's own queries.
  my @my_query_ids = map($_->id, @{$self->queries});
  my $query_id_string = join(',', @my_query_ids) || '-1';

  # Only show subscriptions that we can still actually see. If a
  # user changes the shared group of a query, our subscription
  # will remain but we won't have access to the query anymore.
  my $subscribed_query_ids = Bugzilla->dbh->selectcol_arrayref(
    "SELECT lif.namedquery_id
           FROM namedqueries_link_in_footer lif
                INNER JOIN namedquery_group_map ngm
                ON ngm.namedquery_id = lif.namedquery_id
          WHERE lif.user_id = ?
                AND lif.namedquery_id NOT IN ($query_id_string)
                AND " . $self->groups_in_sql, undef, $self->id
  );
  require Bugzilla::Search::Saved;
  $self->{queries_subscribed}
    = Bugzilla::Search::Saved->new_from_list($subscribed_query_ids);
  return $self->{queries_subscribed};
}

sub queries_available {
  my $self = shift;
  return $self->{queries_available} if defined $self->{queries_available};
  return [] unless $self->id;

  # Exclude the user's own queries.
  my @my_query_ids = map($_->id, @{$self->queries});
  my $query_id_string = join(',', @my_query_ids) || '-1';

  my $avail_query_ids = Bugzilla->dbh->selectcol_arrayref(
    'SELECT namedquery_id FROM namedquery_group_map
          WHERE ' . $self->groups_in_sql . "
                AND namedquery_id NOT IN ($query_id_string)"
  );
  require Bugzilla::Search::Saved;
  $self->{queries_available}
    = Bugzilla::Search::Saved->new_from_list($avail_query_ids);
  return $self->{queries_available};
}

sub tags {
  my $self = shift;
  my $dbh  = Bugzilla->dbh;

  if (!defined $self->{tags}) {

    # We must use LEFT JOIN instead of INNER JOIN as we may be
    # in the process of inserting a new tag to some bugs,
    # in which case there are no bugs with this tag yet.
    $self->{tags} = $dbh->selectall_hashref(
      'SELECT name, id, COUNT(bug_id) AS bug_count
               FROM tag
          LEFT JOIN bug_tag ON bug_tag.tag_id = tag.id
              WHERE user_id = ? ' . $dbh->sql_group_by('id', 'name'), 'name', undef,
      $self->id
    );
  }
  return $self->{tags};
}

sub bugs_ignored {
  my ($self) = @_;
  my $dbh = Bugzilla->dbh;
  if (!defined $self->{'bugs_ignored'}) {
    $self->{'bugs_ignored'} = $dbh->selectall_arrayref(
      'SELECT bugs.bug_id AS id,
                    bugs.bug_status AS status,
                    bugs.short_desc AS summary
               FROM bugs
                    INNER JOIN email_bug_ignore
                    ON bugs.bug_id = email_bug_ignore.bug_id
              WHERE user_id = ?', {Slice => {}}, $self->id
    );

    # Go ahead and load these into the visible bugs cache
    # to speed up can_see_bug checks later
    $self->visible_bugs([map { $_->{'id'} } @{$self->{'bugs_ignored'}}]);
  }
  return $self->{'bugs_ignored'};
}

sub is_bug_ignored {
  my ($self, $bug_id) = @_;
  return (grep { $_->{'id'} == $bug_id } @{$self->bugs_ignored}) ? 1 : 0;
}

##########################
# Saved Recent Bug Lists #
##########################

sub recent_searches {
  my $self = shift;
  $self->{recent_searches}
    ||= Bugzilla::Search::Recent->match({user_id => $self->id});
  return $self->{recent_searches};
}

sub recent_search_containing {
  my ($self, $bug_id) = @_;
  my $searches = $self->recent_searches;

  foreach my $search (@$searches) {
    return $search if grep($_ == $bug_id, @{$search->bug_list});
  }

  return undef;
}

sub recent_search_for {
  my ($self, $bug) = @_;
  my $params = Bugzilla->input_params;
  my $cgi    = Bugzilla->cgi;

  if ($self->id) {

    # First see if there's a list_id parameter in the query string.
    my $list_id = $params->{list_id};
    if (!$list_id) {

      # If not, check for "list_id" in the query string of the referer.
      my $referer = $cgi->referer;
      if ($referer) {
        my $uri = URI->new($referer);
        if ($uri->path =~ /buglist\.cgi$/) {
          $list_id = $uri->query_param('list_id') || $uri->query_param('regetlastlist');
        }
      }
    }

    if ($list_id && $list_id ne 'cookie') {

      # If we got a bad list_id (either some other user's or an expired
      # one) don't crash, just don't return that list.
      my $search = Bugzilla::Search::Recent->check_quietly({id => $list_id});
      return $search if $search;
    }

    # If there's no list_id, see if the current bug's id is contained
    # in any of the user's saved lists.
    my $search = $self->recent_search_containing($bug->id);
    return $search if $search;
  }

  # Finally (or always, if we're logged out), if there's a BUGLIST cookie
  # and the selected bug is in the list, then return the cookie as a fake
  # Search::Recent object.
  if (my $list = $cgi->cookie('BUGLIST')) {

    # Also split on colons, which was used as a separator in old cookies.
    my @bug_ids = split(/[:-]/, $list);
    if (grep { $_ == $bug->id } @bug_ids) {
      my $search = Bugzilla::Search::Recent->new_from_cookie(\@bug_ids);
      return $search;
    }
  }

  return undef;
}

sub save_last_search {
  my ($self, $params) = @_;
  my ($bug_ids, $order, $vars, $list_id) = @$params{qw(bugs order vars list_id)};

  my $cgi = Bugzilla->cgi;
  if ($order) {
    $cgi->send_cookie(
      -name    => 'LASTORDER',
      -value   => $order,
      -expires => 'Fri, 01-Jan-2038 00:00:00 GMT'
    );
  }

  return if !@$bug_ids;

  my $search;
  if ($self->id) {
    on_main_db {
      if ($list_id) {
        $search = Bugzilla::Search::Recent->check_quietly({id => $list_id});
      }

      if ($search) {
        if (join(',', @{$search->bug_list}) ne join(',', @$bug_ids)) {
          $search->set_bug_list($bug_ids);
        }
        if (!$search->list_order || $order ne $search->list_order) {
          $search->set_list_order($order);
        }
        $search->update();
      }
      else {
        # If we already have an existing search with a totally
        # identical bug list, then don't create a new one. This
        # prevents people from writing over their whole
        # recent-search list by just refreshing a saved search
        # (which doesn't have list_id in the header) over and over.
        my $list_string = join(',', @$bug_ids);
        my $existing_search = Bugzilla::Search::Recent->match(
          {user_id => $self->id, bug_list => $list_string});

        if (!scalar(@$existing_search)) {
          $search
            = Bugzilla::Search::Recent->create({
            user_id => $self->id, bug_list => $bug_ids, list_order => $order
            });
        }
        else {
          $search = $existing_search->[0];
        }
      }
    };
    delete $self->{recent_searches};
  }

  # Logged-out users use a cookie to store a single last search. We don't
  # override that cookie with the logged-in user's latest search, because
  # if they did one search while logged out and another while logged in,
  # they may still want to navigate through the search they made while
  # logged out.
  else {
    my $bug_list = join('-', @$bug_ids);
    if (length($bug_list) < 4000) {
      $cgi->send_cookie(
        -name    => 'BUGLIST',
        -value   => $bug_list,
        -expires => 'Fri, 01-Jan-2038 00:00:00 GMT'
      );
    }
    else {
      $cgi->remove_cookie('BUGLIST');
      $vars->{'toolong'} = 1;
    }
  }
  return $search;
}

sub settings {
  my ($self) = @_;

  return $self->{'settings'} if (defined $self->{'settings'});

  # IF the user is logged in
  # THEN get the user's settings
  # ELSE get default settings
  if ($self->id) {
    $self->{'settings'} = get_all_settings($self->id);
  }
  else {
    $self->{'settings'} = get_defaults();
  }

  return $self->{'settings'};
}

sub setting {
  my ($self, $name) = @_;
  return $self->settings->{$name}->{'value'};
}

sub timezone {
  my $self = shift;

  if (!defined $self->{timezone}) {
    my $tz = $self->setting('timezone');
    if ($tz eq 'local') {

      # The user wants the local timezone of the server.
      $self->{timezone} = Bugzilla->local_timezone;
    }
    else {
      $self->{timezone} = DateTime::TimeZone->new(name => $tz);
    }
  }
  return $self->{timezone};
}

sub flush_queries_cache {
  my $self = shift;

  delete $self->{queries};
  delete $self->{queries_subscribed};
  delete $self->{queries_available};
}

sub groups {
  my $self = shift;

  return $self->{groups} if defined $self->{groups};
  return [] unless $self->id;

  my $user_groups_key = "user_groups." . $self->id;
  my $groups = Bugzilla->memcached->get_config({key => $user_groups_key});

  if (!$groups) {
    my $dbh             = Bugzilla->dbh;
    my $groups_to_check = $dbh->selectcol_arrayref(
      "SELECT DISTINCT group_id
               FROM user_group_map
              WHERE user_id = ? AND isbless = 0", undef, $self->id
    );

    my $grant_type_key = 'group_grant_type_' . GROUP_MEMBERSHIP;
    my $membership_rows
      = Bugzilla->memcached->get_config({key => $grant_type_key,});
    if (!$membership_rows) {
      $membership_rows = $dbh->selectall_arrayref(
        "SELECT DISTINCT grantor_id, member_id
                FROM group_group_map
                WHERE grant_type = " . GROUP_MEMBERSHIP
      );
      Bugzilla->memcached->set_config({
        key => $grant_type_key, data => $membership_rows,
      });
    }

    my %group_membership;
    foreach my $row (@$membership_rows) {
      my ($grantor_id, $member_id) = @$row;
      push(@{$group_membership{$member_id}}, $grantor_id);
    }

    # Let's walk the groups hierarchy tree (using FIFO)
    # On the first iteration it's pre-filled with direct groups
    # membership. Later on, each group can add its own members into the
    # FIFO. Circular dependencies are eliminated by checking
    # $checked_groups{$member_id} hash values.
    # As a result, %groups will have all the groups we are the member of.
    my %checked_groups;
    my %groups;
    while (scalar(@$groups_to_check) > 0) {

      # Pop the head group from FIFO
      my $member_id = shift @$groups_to_check;

      # Skip the group if we have already checked it
      if (!$checked_groups{$member_id}) {

        # Mark group as checked
        $checked_groups{$member_id} = 1;

        # Add all its members to the FIFO check list
        # %group_membership contains arrays of group members
        # for all groups. Accessible by group number.
        my $members = $group_membership{$member_id};
        my @new_to_check = grep(!$checked_groups{$_}, @$members);
        push(@$groups_to_check, @new_to_check);

        $groups{$member_id} = 1;
      }
    }
    $groups = [keys %groups];

    Bugzilla->memcached->set_config({key => $user_groups_key, data => $groups,});
  }

  $self->{groups} = Bugzilla::Group->new_from_list($groups);
  return $self->{groups};
}

sub force_bug_dissociation {
  my ($self, $nobody, $groups, $timestamp) = @_;
  my $dbh       = Bugzilla->dbh;
  my $auto_user = Bugzilla->user;
  $timestamp //= $dbh->selectrow_array('SELECT LOCALTIMESTAMP(0)');

  my $group_marks = join(", ", ('?') x @$groups);
  my $user_id     = $self->id;
  my @params      = (
    $user_id, $user_id, $user_id, $user_id,
    map { blessed $_ ? $_->id : $_ } @$groups
  );
  my $bugs = $dbh->selectall_arrayref(
    qq{
        SELECT
            bugs.bug_id,
            bugs.reporter_accessible,
            bugs.reporter    = ? AS match_reporter,
            bugs.assigned_to = ? AS match_assignee,
            bugs.qa_contact  = ? AS match_qa_contact,
            cc.who           = ? AS match_cc
        FROM
            bug_group_map
                JOIN
            bugs ON bug_group_map.bug_id = bugs.bug_id
                LEFT JOIN
            cc ON cc.bug_id = bugs.bug_id
        WHERE
            group_id IN ($group_marks)
        HAVING match_reporter AND reporter_accessible
            OR match_assignee
            OR match_qa_contact
            OR match_cc
    }, {Slice => {}}, @params
  );

  my @reporter_bugs = map { $_->{bug_id} } grep { $_->{match_reporter} } @$bugs;
  my @assignee_bugs = map { $_->{bug_id} } grep { $_->{match_assignee} } @$bugs;
  my @qa_bugs       = map { $_->{bug_id} } grep { $_->{match_qa_contact} } @$bugs;
  my @cc_bugs       = map { $_->{bug_id} } grep { $_->{match_cc} } @$bugs;

  # Reporter - set reporter_accessible to false
  my $reporter_accessible_field_id = get_field_id('reporter_accessible');
  foreach my $bug_id (@reporter_bugs) {
    $dbh->do(
      q{INSERT INTO bugs_activity (bug_id, who, bug_when, fieldid, removed, added)
            VALUES (?, ?, ?, ?, ?, ?)}, undef, $bug_id, $auto_user->id, $timestamp,
      $reporter_accessible_field_id, 1, 0
    );
    $dbh->do(
      q{UPDATE bugs SET reporter_accessible = 0, delta_ts = ?, lastdiffed = ?
            WHERE bug_id = ?}, undef, $timestamp, $timestamp, $bug_id
    );
  }

  # Assignee
  my $assigned_to_field_id = get_field_id('assigned_to');
  foreach my $bug_id (@assignee_bugs) {
    $dbh->do(
      q{INSERT INTO bugs_activity (bug_id, who, bug_when, fieldid, removed, added)
            VALUES (?, ?, ?, ?, ?, ?)}, undef, $bug_id, $auto_user->id, $timestamp,
      $assigned_to_field_id, $self->login, $auto_user->login
    );
    $dbh->do(
      q{UPDATE bugs SET assigned_to = ?, delta_ts = ?, lastdiffed = ?
            WHERE bug_id = ?}, undef, $nobody->id, $timestamp, $timestamp, $bug_id
    );
  }

  # QA Contact
  my $qa_field_id = get_field_id('qa_contact');
  foreach my $bug_id (@qa_bugs) {
    $dbh->do(
      q{INSERT INTO bugs_activity (bug_id, who, bug_when, fieldid, removed, added)
            VALUES (?, ?, ?, ?, ?, '')}, undef, $bug_id, $auto_user->id, $timestamp,
      $qa_field_id, $self->login
    );
    $dbh->do(
      q{UPDATE bugs SET qa_contact = NULL, delta_ts = ?, lastdiffed = ?
            WHERE bug_id = ?}, undef, $timestamp, $timestamp, $bug_id
    );
  }

  # CC list
  my $cc_field_id = get_field_id('cc');
  foreach my $bug_id (@cc_bugs) {
    $dbh->do(
      q{INSERT INTO bugs_activity (bug_id, who, bug_when, fieldid, removed, added)
            VALUES (?, ?, ?, ?, ?, '')}, undef, $bug_id, $auto_user->id, $timestamp,
      $cc_field_id, $self->login
    );
    $dbh->do(q{DELETE FROM cc WHERE bug_id = ? AND who = ?},
      undef, $bug_id, $self->id);
  }

  if (@reporter_bugs || @assignee_bugs || @qa_bugs || @cc_bugs) {
    $self->clear_last_statistics_ts();

    # It's complex to determine which items now need to be flushed from memcached.
    # As this is expected to be a rare event, we just flush the entire cache.
    Bugzilla->memcached->clear_all();
  }

  return $bugs;
}

sub last_visited {
  my ($self) = @_;

  return Bugzilla::BugUserLastVisit->match({user_id => $self->id});
}

sub is_involved_in_bug {
  my ($self, $bug) = @_;
  my $user_id    = $self->id;
  my $user_login = $self->login;

  return unless $user_id;
  return 1 if $user_id == $bug->assigned_to->id;
  return 1 if $user_id == $bug->reporter->id;

  if (Bugzilla->params->{'useqacontact'} and $bug->qa_contact) {
    return 1 if $user_id == $bug->qa_contact->id;
  }

  # BMO - Bug mentors are considered involved with the bug
  return 1 if $bug->is_mentor($self);

  return unless $bug->cc;
  return any { $user_login eq $_ } @{$bug->cc};
}

# It turns out that calling ->id on objects a few hundred thousand
# times is pretty slow. (It showed up as a significant time contributor
# when profiling xt/search.t.) So we cache the group ids separately from
# groups for functions that need the group ids.
sub _group_ids {
  my ($self) = @_;
  $self->{group_ids} ||= [map { $_->id } @{$self->groups}];
  return $self->{group_ids};
}

sub groups_as_string {
  my $self = shift;
  my $ids  = $self->_group_ids;
  return scalar(@$ids) ? join(',', @$ids) : '-1';
}

sub groups_in_sql {
  my ($self, $field) = @_;
  $field ||= 'group_id';
  my $ids = $self->_group_ids;
  $ids = [-1] if !scalar @$ids;
  return Bugzilla->dbh->sql_in($field, $ids);
}

sub groups_owned {
  my $self = shift;
  return $self->{groups_owned}
    //= Bugzilla::Group->match({owner_user_id => $self->id});
}

sub bless_groups {
  my $self = shift;

  return $self->{'bless_groups'} if defined $self->{'bless_groups'};
  return [] unless $self->id;

  if ($self->in_group('admin')) {

    # Users having admin permissions may bless all groups.
    $self->{'bless_groups'} = [Bugzilla::Group->get_all];
    return $self->{'bless_groups'};
  }

  if (Bugzilla->params->{usevisibilitygroups} && !$self->visible_groups_inherited)
  {
    return [];
  }

  my $dbh = Bugzilla->dbh;

  # Get all groups for the user where they have direct bless privileges.
  my $query = "
        SELECT DISTINCT group_id
          FROM user_group_map
         WHERE user_id = ?
               AND isbless = 1";
  if (Bugzilla->params->{usevisibilitygroups}) {
    $query .= " AND " . $dbh->sql_in('group_id', $self->visible_groups_inherited);
  }

  # Get all groups for the user where they are a member of a group that
  # inherits bless privs.
  my @group_ids = map { $_->id } @{$self->groups};
  if (@group_ids) {
    $query .= "
            UNION
            SELECT DISTINCT grantor_id
            FROM group_group_map
            WHERE grant_type = " . GROUP_BLESS . "
                AND " . $dbh->sql_in('member_id', \@group_ids);
    if (Bugzilla->params->{usevisibilitygroups}) {
      $query .= " AND " . $dbh->sql_in('grantor_id', $self->visible_groups_inherited);
    }
  }

  my $ids = $dbh->selectcol_arrayref($query, undef, $self->id);
  return $self->{bless_groups} = Bugzilla::Group->new_from_list($ids);
}

sub in_group {
  my ($self, $group, $product_id) = @_;
  $group = $group->name if blessed $group;
  $self->{in_group} //= {map { $_->name => $_ } @{$self->groups}};

  if ($self->{in_group}{$group}) {
    return 1;
  }
  elsif ($product_id && detaint_natural($product_id)) {

    # Make sure $group exists on a per-product basis.
    return 0 unless (grep { $_ eq $group } PER_PRODUCT_PRIVILEGES);

    $self->{"product_$product_id"} = {}
      unless exists $self->{"product_$product_id"};
    if (!defined $self->{"product_$product_id"}->{$group}) {
      my $dbh      = Bugzilla->dbh;
      my $in_group = $dbh->selectrow_array(
        "SELECT 1
                              FROM group_control_map
                             WHERE product_id = ?
                                   AND $group != 0
                                   AND "
          . $self->groups_in_sql . ' ' . $dbh->sql_limit(1), undef, $product_id
      );

      $self->{"product_$product_id"}->{$group} = $in_group ? 1 : 0;
    }
    return $self->{"product_$product_id"}->{$group};
  }

  # If we come here, then the user is not in the requested group.
  return 0;
}

sub in_group_id {
  my ($self, $id) = @_;
  return grep($_->id == $id, @{$self->groups}) ? 1 : 0;
}

# This is a helper to get all groups which have an icon to be displayed
# besides the name of the commenter.
sub groups_with_icon {
  my $self = shift;

  return $self->{groups_with_icon} //= [grep { $_->icon_url } @{$self->groups}];
}

sub get_products_by_permission {
  my ($self, $group) = @_;

  # Make sure $group exists on a per-product basis.
  return [] unless (grep { $_ eq $group } PER_PRODUCT_PRIVILEGES);

  my $product_ids = Bugzilla->dbh->selectcol_arrayref(
    "SELECT DISTINCT product_id
                             FROM group_control_map
                            WHERE $group != 0
                              AND " . $self->groups_in_sql
  );

  # No need to go further if the user has no "special" privs.
  return [] unless scalar(@$product_ids);
  my %product_map = map { $_ => 1 } @$product_ids;

  # We will restrict the list to products the user can see.
  my $selectable_products = $self->get_selectable_products;
  my @products = grep { $product_map{$_->id} } @$selectable_products;
  return \@products;
}

sub can_see_user {
  my ($self, $otherUser) = @_;
  my $query;

  if (Bugzilla->params->{'usevisibilitygroups'}) {

    # If the user can see no groups, then no users are visible either.
    my $visibleGroups = $self->visible_groups_as_string() || return 0;
    $query = qq{SELECT COUNT(DISTINCT userid)
                    FROM profiles, user_group_map
                    WHERE userid = ?
                    AND user_id = userid
                    AND isbless = 0
                    AND group_id IN ($visibleGroups)
                   };
  }
  else {
    $query = qq{SELECT COUNT(userid)
                    FROM profiles
                    WHERE userid = ?
                   };
  }
  return Bugzilla->dbh->selectrow_array($query, undef, $otherUser->id);
}

sub can_edit_product {
  my ($self, $prod_id) = @_;
  my $dbh = Bugzilla->dbh;

  my $has_external_groups = $dbh->selectrow_array(
    'SELECT 1
                               FROM group_control_map
                              WHERE product_id = ?
                                AND canedit != 0
                                AND group_id NOT IN('
      . $self->groups_as_string . ')', undef, $prod_id
  );

  return !$has_external_groups;
}

sub can_see_bug {
  my ($self, $bug_id) = @_;
  return @{$self->visible_bugs([$bug_id])} ? 1 : 0;
}

sub visible_bugs {
  my ($self, $bugs) = @_;

  # Allow users to pass in Bug objects and bug ids both.
  my @bug_ids = map { blessed $_ ? $_->id : $_ } @$bugs;

  # We only check the visibility of bugs that we haven't
  # checked yet.
  # Bugzilla::Bug->update automatically removes updated bugs
  # from the cache to force them to be checked again.
  my $visible_cache = $self->{_visible_bugs_cache} ||= {};
  my @check_ids = grep(!exists $visible_cache->{$_}, @bug_ids);

  if (@check_ids) {
    my $dbh     = Bugzilla->dbh;
    my $user_id = $self->id;

    foreach my $id (@check_ids) {
      my $orig_id = $id;
      detaint_natural($id)
        || ThrowCodeError('param_must_be_numeric',
        {param => $orig_id, function => 'Bugzilla::User->visible_bugs'});
    }

    my $sth;

    # Speed up the can_see_bug case.
    if (scalar(@check_ids) == 1) {
      $sth = $self->{_sth_one_visible_bug};
    }
    $sth ||= $dbh->prepare(

      # This checks for groups that the bug is in that the user
      # *isn't* in. Then, in the Perl code below, we check if
      # the user can otherwise access the bug (for example, by being
      # the assignee or QA Contact).
      #
      # The DISTINCT exists because the bug could be in *several*
      # groups that the user isn't in, but they will all return the
      # same result for bug_group_map.bug_id (so DISTINCT filters
      # out duplicate rows).
      "SELECT DISTINCT bugs.bug_id, reporter, assigned_to, qa_contact,
                    components.triage_owner_id, reporter_accessible,
                    cclist_accessible, cc.who, bug_group_map.bug_id
               FROM bugs
                    LEFT JOIN cc
                              ON cc.bug_id = bugs.bug_id
                                 AND cc.who = $user_id
                    LEFT JOIN components
                              ON bugs.component_id = components.id
                    LEFT JOIN bug_group_map
                              ON bugs.bug_id = bug_group_map.bug_id
                                 AND bug_group_map.group_id NOT IN ("
        . $self->groups_as_string . ')
              WHERE bugs.bug_id IN (' . join(',', ('?') x @check_ids) . ')
                    AND creation_ts IS NOT NULL '
    );
    if (scalar(@check_ids) == 1) {
      $self->{_sth_one_visible_bug} = $sth;
    }

    $sth->execute(@check_ids);
    my $use_qa_contact = Bugzilla->params->{'useqacontact'};
    while (my $row = $sth->fetchrow_arrayref) {
      my ($bug_id, $reporter, $owner, $qacontact, $triage_owner, $reporter_access,
          $cclist_access, $isoncclist, $missinggroup)
        = @$row;
      $visible_cache->{$bug_id}
        ||= ((($reporter == $user_id) && $reporter_access)
          || ($use_qa_contact && $qacontact && ($qacontact == $user_id))
          || ($triage_owner && $triage_owner == $user_id)
          || ($owner == $user_id)
          || ($isoncclist && $cclist_access)
          || !$missinggroup) ? 1 : 0;
    }
  }

  return [grep { $visible_cache->{blessed $_ ? $_->id : $_} } @$bugs];
}

sub clear_product_cache {
  my $self = shift;
  delete $self->{enterable_products};
  delete $self->{selectable_products};
  delete $self->{selectable_classifications};
}

sub can_see_product {
  my ($self, $product_name) = @_;

  return any { $_->name eq $product_name } @{$self->get_selectable_products};
}

sub get_selectable_products {
  my $self             = shift;
  my $class_id         = shift;
  my $class_restricted = Bugzilla->params->{'useclassification'} && $class_id;

  if (!defined $self->{selectable_products}) {
    my $query
      = "SELECT id "
      . "  FROM products "
      . "LEFT JOIN group_control_map "
      . "ON group_control_map.product_id = products.id "
      . " AND group_control_map.membercontrol = "
      . CONTROLMAPMANDATORY
      . " AND group_id NOT IN("
      . $self->groups_as_string . ") "
      . "   WHERE group_id IS NULL "
      . "ORDER BY name";

    my $prod_ids = Bugzilla->dbh->selectcol_arrayref($query);
    $self->{selectable_products} = Bugzilla::Product->new_from_list($prod_ids);
  }

  # Restrict the list of products to those being in the classification, if any.
  if ($class_restricted) {
    return [grep { $_->classification_id == $class_id }
        @{$self->{selectable_products}}];
  }

  # If we come here, then we want all selectable products.
  return $self->{selectable_products};
}

sub get_selectable_classifications {
  my ($self) = @_;

  if (!defined $self->{selectable_classifications}) {
    my $products = $self->get_selectable_products;
    my %class_ids = map { $_->classification_id => 1 } @$products;

    $self->{selectable_classifications}
      = Bugzilla::Classification->new_from_list([keys %class_ids]);
  }
  return $self->{selectable_classifications};
}

sub can_enter_product {
  my ($self, $input, $warn) = @_;
  my $dbh = Bugzilla->dbh;
  $warn ||= 0;

  $input = trim($input) if !ref $input;
  if (!defined $input or $input eq '') {
    return unless $warn == THROW_ERROR;
    ThrowUserError('object_not_specified', {class => 'Bugzilla::Product'});
  }

  if (!scalar @{$self->get_enterable_products}) {
    return unless $warn == THROW_ERROR;
    ThrowUserError('no_products');
  }

  my $product
    = blessed($input) ? $input : new Bugzilla::Product({name => $input});
  my $can_enter = $product
    && grep($_->name eq $product->name, @{$self->get_enterable_products});

  return $product if $can_enter;

  return 0 unless $warn == THROW_ERROR;

  # Check why access was denied. These checks are slow,
  # but that's fine, because they only happen if we fail.

  # We don't just use $product->name for error messages, because if it
  # changes case from $input, then that's a clue that the product does
  # exist but is hidden.
  my $name = blessed($input) ? $input->name : $input;

  # The product could not exist or you could be denied...
  if (!$product || !$product->user_has_access($self)) {
    ThrowUserError('entry_access_denied', {product => $name});
  }

  # It could be closed for bug entry...
  elsif (!$product->is_active) {
    ThrowUserError('product_disabled', {product => $product});
  }

  # It could have no components...
  elsif (!@{$product->components}
    || !grep { $_->is_active } @{$product->components})
  {
    ThrowUserError('missing_component', {product => $product});
  }

  # It could have no versions...
  elsif (!@{$product->versions} || !grep { $_->is_active } @{$product->versions})
  {
    ThrowUserError('missing_version', {product => $product});
  }

  die "can_enter_product reached an unreachable location.";
}

sub get_enterable_products {
  my $self = shift;
  my $dbh  = Bugzilla->dbh;

  if (defined $self->{enterable_products}) {
    return $self->{enterable_products};
  }

  # All products which the user has "Entry" access to.
  my $enterable_ids = $dbh->selectcol_arrayref(
    'SELECT products.id FROM products
         LEFT JOIN group_control_map
                   ON group_control_map.product_id = products.id
                      AND group_control_map.entry != 0
                      AND group_id NOT IN (' . $self->groups_as_string . ')
            WHERE group_id IS NULL
                  AND products.isactive = 1'
  );

  if (scalar @$enterable_ids) {

    # And all of these products must have at least one component
    # and one version.
    $enterable_ids = $dbh->selectcol_arrayref(
      'SELECT DISTINCT products.id FROM products
              WHERE '
        . $dbh->sql_in('products.id', $enterable_ids)
        . ' AND products.id IN (SELECT DISTINCT components.product_id
                                      FROM components
                                     WHERE components.isactive = 1)
                AND products.id IN (SELECT DISTINCT versions.product_id
                                      FROM versions
                                     WHERE versions.isactive = 1)'
    );
  }

  $self->{enterable_products} = Bugzilla::Product->new_from_list($enterable_ids);
  return $self->{enterable_products};
}

sub can_access_product {
  my ($self, $product) = @_;
  my $product_name = blessed($product) ? $product->name : $product;
  return
    scalar(grep { $_->name eq $product_name } @{$self->get_accessible_products});
}

sub get_accessible_products {
  my $self = shift;

  # Map the objects into a hash using the ids as keys
  my %products = map { $_->id => $_ } @{$self->get_selectable_products},
    @{$self->get_enterable_products};

  return [sort { $a->name cmp $b->name } values %products];
}

sub check_can_admin_product {
  my ($self, $product_name) = @_;

  # First make sure the product name is valid.
  my $product = Bugzilla::Product->check($product_name);

  (      $self->in_group('editcomponents', $product->id)
      && $self->can_see_product($product->name))
    || ThrowUserError('product_admin_denied', {product => $product->name});

  # Return the validated product object.
  return $product;
}

sub check_can_admin_flagtype {
  my ($self, $flagtype_id) = @_;

  my $flagtype = Bugzilla::FlagType->check({id => $flagtype_id});
  my $can_fully_edit = 1;

  if (!$self->in_group('editcomponents')) {
    my $products = $self->get_products_by_permission('editcomponents');

    # You need editcomponents privs for at least one product to have
    # a chance to edit the flagtype.
    scalar(@$products)
      || ThrowUserError('auth_failure',
      {group => 'editcomponents', action => 'edit', object => 'flagtypes'});
    my $can_admin = 0;
    my $i         = $flagtype->inclusions_as_hash;
    my $e         = $flagtype->exclusions_as_hash;

    # If there is at least one product for which the user doesn't have
    # editcomponents privs, then don't allow them to do everything with
    # this flagtype, independently of whether this product is in the
    # exclusion list or not.
    my %product_ids;
    map { $product_ids{$_->id} = 1 } @$products;
    $can_fully_edit = 0 if grep { !$product_ids{$_} } keys %$i;

    unless ($e->{0}->{0}) {
      foreach my $product (@$products) {
        my $id = $product->id;
        next if $e->{$id}->{0};

        # If we are here, the product has not been explicitly excluded.
        # Check whether it's explicitly included, or at least one of
        # its components.
        $can_admin
          = (  $i->{0}->{0}
            || $i->{$id}->{0}
            || scalar(grep { !$e->{$id}->{$_} } keys %{$i->{$id}}));
        last if $can_admin;
      }
    }
    $can_admin || ThrowUserError('flag_type_not_editable', {flagtype => $flagtype});
  }
  return wantarray ? ($flagtype, $can_fully_edit) : $flagtype;
}

sub can_change_flag {
  my ($self, $flag_type, $old_status, $new_status) = @_;

  # "old_status:new_status" => [OR conditions
  state $flag_transitions = {
    'X:-' => ['grant_group'],
    'X:+' => ['grant_group'],
    'X:?' => ['request_group'],

    '?:X' => ['request_group', 'is_setter'],
    '?:-' => ['grant_group'],
    '?:+' => ['grant_group'],

    '+:X' => ['grant_group'],
    '+:-' => ['grant_group'],
    '+:?' => ['grant_group'],

    '-:X' => ['grant_group'],
    '-:+' => ['grant_group'],
    '-:?' => ['grant_group'],
  };

  return 1 if $new_status eq $old_status;

  my $action = "$old_status:$new_status";
  my %bool   = (
    request_group => $self->can_request_flag($flag_type),
    grant_group   => $self->can_set_flag($flag_type),
    is_setter     => $self->id == Bugzilla->user->id,
  );

  my $cond = $flag_transitions->{$action};
  if ($cond) {
    if (any { $bool{$_} } @$cond) {
      return 1;
    }
    else {
      return 0;
    }
  }
  else {
    warn "unknown flag transition blocked: $action";
    return 0;
  }
}

sub can_request_flag {
  my ($self, $flag_type) = @_;

  return ($self->can_set_flag($flag_type)
      || !$flag_type->request_group_id
      || $self->in_group_id($flag_type->request_group_id)) ? 1 : 0;
}

sub can_set_flag {
  my ($self, $flag_type) = @_;

  return (!$flag_type->grant_group_id
      || $self->in_group_id($flag_type->grant_group_id)) ? 1 : 0;
}

sub can_unset_flag {
  my ($self, $flag_type, $flag_status) = @_;
  return 1 if !$flag_type->grant_group_id;
  return 1 if ($flag_status ne '+' && $flag_status ne '-');
  return $self->in_group_id($flag_type->grant_group_id) ? 1 : 0;
}

# visible_groups_inherited returns a reference to a list of all the groups
# whose members are visible to this user.
sub visible_groups_inherited {
  my $self = shift;
  return $self->{visible_groups_inherited}
    if defined $self->{visible_groups_inherited};
  return [] unless $self->id;
  my @visgroups = @{$self->visible_groups_direct};
  @visgroups = @{Bugzilla::Group->flatten_group_membership(@visgroups)};
  $self->{visible_groups_inherited} = \@visgroups;
  return $self->{visible_groups_inherited};
}

# visible_groups_direct returns a reference to a list of all the groups that
# are visible to this user.
sub visible_groups_direct {
  my $self      = shift;
  my @visgroups = ();
  return $self->{visible_groups_direct} if defined $self->{visible_groups_direct};
  return [] unless $self->id;

  my $dbh = Bugzilla->dbh;
  my $sth;

  if (Bugzilla->params->{'usevisibilitygroups'}) {
    $sth = $dbh->prepare(
      "SELECT DISTINCT grantor_id
                                 FROM group_group_map
                                WHERE " . $self->groups_in_sql('member_id') . "
                                  AND grant_type=" . GROUP_VISIBLE
    );
  }
  else {
    # All groups are visible if usevisibilitygroups is off.
    $sth = $dbh->prepare('SELECT id FROM ' . $dbh->quote_identifier('groups'));
  }
  $sth->execute();

  while (my ($row) = $sth->fetchrow_array) {
    push @visgroups, $row;
  }
  $self->{visible_groups_direct} = \@visgroups;

  return $self->{visible_groups_direct};
}

sub visible_groups_as_string {
  my $self = shift;
  return join(', ', @{$self->visible_groups_inherited()});
}

# This function defines the groups a user may share a query with.
# More restrictive sites may want to build this reference to a list of group IDs
# from bless_groups instead of mirroring visible_groups_inherited, perhaps.
sub queryshare_groups {
  my $self = shift;
  my @queryshare_groups;

  return $self->{queryshare_groups} if defined $self->{queryshare_groups};

  if ($self->in_group(Bugzilla->params->{'querysharegroup'})) {

    # We want to be allowed to share with groups we're in only.
    # If usevisibilitygroups is on, then we need to restrict this to groups
    # we may see.
    if (Bugzilla->params->{'usevisibilitygroups'}) {
      foreach (@{$self->visible_groups_inherited()}) {
        next unless $self->in_group_id($_);
        push(@queryshare_groups, $_);
      }
    }
    else {
      @queryshare_groups = @{$self->_group_ids};
    }
  }

  return $self->{queryshare_groups} = \@queryshare_groups;
}

sub queryshare_groups_as_string {
  my $self = shift;
  return join(', ', @{$self->queryshare_groups()});
}

sub derive_regexp_groups {
  my ($self) = @_;

  my $id = $self->id;
  return unless $id;

  my $dbh = Bugzilla->dbh;

  my $sth;

  # add derived records for any matching regexps

  $sth = $dbh->prepare(
    "SELECT id, userregexp, user_group_map.group_id
                            FROM " . $dbh->quote_identifier('groups') . "
                       LEFT JOIN user_group_map
                              ON groups.id = user_group_map.group_id
                             AND user_group_map.user_id = ?
                             AND user_group_map.grant_type = ?"
  );
  $sth->execute($id, GRANT_REGEXP);

  my $group_insert = $dbh->prepare(
    q{INSERT INTO user_group_map
                                       (user_id, group_id, isbless, grant_type)
                                       VALUES (?, ?, 0, ?)}
  );
  my $group_delete = $dbh->prepare(
    q{DELETE FROM user_group_map
                                       WHERE user_id = ?
                                         AND group_id = ?
                                         AND isbless = 0
                                         AND grant_type = ?}
  );
  while (my ($group, $regexp, $present) = $sth->fetchrow_array()) {
    if (($regexp ne '') && ($self->login =~ m/$regexp/i)) {
      $group_insert->execute($id, $group, GRANT_REGEXP) unless $present;
    }
    else {
      $group_delete->execute($id, $group, GRANT_REGEXP) if $present;
    }
  }

  Bugzilla->memcached->clear_config({key => "user_groups.$id"});
}

sub product_responsibilities {
  my $self = shift;
  my $dbh  = Bugzilla->dbh;

  return $self->{'product_resp'} if defined $self->{'product_resp'};
  return [] unless $self->id;

  my $list = $dbh->selectall_arrayref(
    'SELECT components.product_id, components.id
                                           FROM components
                                           LEFT JOIN component_cc
                                           ON components.id = component_cc.component_id
                                          WHERE components.initialowner = ?
                                             OR components.initialqacontact = ?
                                             OR components.triage_owner_id = ?
                                             OR component_cc.user_id = ?',
    {Slice => {}}, ($self->id, $self->id, $self->id, $self->id)
  );

  unless ($list) {
    $self->{'product_resp'} = [];
    return $self->{'product_resp'};
  }

  my @prod_ids = map { $_->{'product_id'} } @$list;
  my $products = Bugzilla::Product->new_from_list(\@prod_ids);

  # We cannot |use| it, because Component.pm already |use|s User.pm.
  require Bugzilla::Component;
  my @comp_ids = map { $_->{'id'} } @$list;
  my $components = Bugzilla::Component->new_from_list(\@comp_ids);

  my @prod_list;

  # @$products is already sorted alphabetically.
  foreach my $prod (@$products) {

    # We use @components instead of $prod->components because we only want
    # components where the user is either the default assignee or QA contact.
    push(
      @prod_list,
      {
        product    => $prod,
        components => [grep { $_->product_id == $prod->id } @$components]
      }
    );
  }
  $self->{'product_resp'} = \@prod_list;
  return $self->{'product_resp'};
}

sub can_bless {
  my $self = shift;

  if (!scalar(@_)) {

    # If we're called without an argument, just return
    # whether or not we can bless at all.
    return scalar(@{$self->bless_groups}) ? 1 : 0;
  }

  # Otherwise, we're checking a specific group
  my $group_id = shift;
  return grep($_->id == $group_id, @{$self->bless_groups}) ? 1 : 0;
}

sub match {

  # Generates a list of users whose login name (email address) or real name
  # matches a substring or wildcard.
  # This is also called if matches are disabled (for error checking), but
  # in this case only the exact match code will end up running.

  # $str contains the string to match, while $limit contains the
  # maximum number of records to retrieve.
  my ($str, $limit, $exclude_disabled) = @_;
  my $user = Bugzilla->user;
  my $dbh  = Bugzilla->dbh;

  $str = trim($str);

  my @users = ();
  return \@users if $str =~ /^\s*$/;

  # The search order is wildcards, then exact match, then substring search.
  # Wildcard matching is skipped if there is no '*', and exact matches will
  # not (?) have a '*' in them.  If any search comes up with something, the
  # ones following it will not execute.

  # first try wildcards
  my $wildstr = $str;

  # Do not do wildcards if there is no '*' in the string.
  if ($wildstr =~ s/\*/\%/g && $user->id) {

    # Build the query.
    my $query = "SELECT DISTINCT userid FROM profiles ";
    if (Bugzilla->params->{'usevisibilitygroups'}) {
      $query .= "INNER JOIN user_group_map
                               ON user_group_map.user_id = profiles.userid ";
    }
    $query
      .= "WHERE ("
      . $dbh->sql_istrcmp('login_name', '?', "LIKE") . " OR "
      . $dbh->sql_istrcmp('realname',   '?', "LIKE") . ") ";
    if (Bugzilla->params->{'usevisibilitygroups'}) {
      $query
        .= "AND isbless = 0 "
        . "AND group_id IN("
        . join(', ', (-1, @{$user->visible_groups_inherited})) . ") ";
    }
    $query .= " AND is_enabled = 1 "  if $exclude_disabled;
    $query .= $dbh->sql_limit($limit) if $limit;

    # Execute the query, retrieve the results, and make them into
    # User objects.
    my $user_ids = $dbh->selectcol_arrayref($query, undef, ($wildstr, $wildstr));
    @users = @{Bugzilla::User->new_from_list($user_ids)};
  }
  else {    # try an exact match
            # Exact matches don't care if a user is disabled.
    my $user_id = $dbh->selectrow_array(
      'SELECT userid FROM profiles
                                             WHERE '
        . $dbh->sql_istrcmp('login_name', '?'), undef, $str
    );

    push(@users, new Bugzilla::User($user_id)) if $user_id;
  }

  # then try substring search
  if (!scalar(@users) && length($str) >= 3 && $user->id) {

    my $query = "SELECT DISTINCT userid FROM profiles ";
    if (Bugzilla->params->{'usevisibilitygroups'}) {
      $query .= "INNER JOIN user_group_map
                               ON user_group_map.user_id = profiles.userid ";
    }
    $query
      .= " WHERE ("
      . $dbh->sql_iposition('?', 'login_name') . " > 0" . " OR "
      . $dbh->sql_iposition('?', 'realname')
      . " > 0) ";
    if (Bugzilla->params->{'usevisibilitygroups'}) {
      $query
        .= " AND isbless = 0"
        . " AND group_id IN("
        . join(', ', (-1, @{$user->visible_groups_inherited})) . ") ";
    }
    $query .= " AND is_enabled = 1 "  if $exclude_disabled;
    $query .= $dbh->sql_limit($limit) if $limit;
    my $user_ids = $dbh->selectcol_arrayref($query, undef, ($str, $str));
    @users = @{Bugzilla::User->new_from_list($user_ids)};
  }
  return \@users;
}

sub match_field {
  my $fields = shift;                            # arguments as a hash
  my $data = shift || Bugzilla->input_params;    # hash to look up fields in
  my $behavior       = shift || 0;    # A constant that tells us how to act
  my $matches        = {};            # the values sent to the template
  my $matchsuccess   = 1;             # did the match fail?
  my $need_confirm   = 0;             # whether to display confirmation screen
  my $match_multiple = 0;             # whether we ever matched more than one user
  my @non_conclusive_fields;          # fields which don't have a unique user.

  my $params = Bugzilla->params;

  # prepare default form values

  # Fields can be regular expressions matching multiple form fields
  # (f.e. "requestee-(\d+)"), so expand each non-literal field
  # into the list of form fields it matches.
  my $expanded_fields = {};
  foreach my $field_pattern (keys %{$fields}) {

    # Check if the field has any non-word characters.  Only those fields
    # can be regular expressions, so don't expand the field if it doesn't
    # have any of those characters.
    if ($field_pattern =~ /^\w+$/) {
      $expanded_fields->{$field_pattern} = $fields->{$field_pattern};
    }
    else {
      my @field_names = grep(/$field_pattern/, keys %$data);

      foreach my $field_name (@field_names) {
        $expanded_fields->{$field_name} = {type => $fields->{$field_pattern}->{'type'}};

        # The field is a requestee field; in order for its name
        # to show up correctly on the confirmation page, we need
        # to find out the name of its flag type.
        if ($field_name =~ /^requestee(_type)?-(\d+)$/) {
          my $flag_type;
          if ($1) {
            require Bugzilla::FlagType;
            $flag_type = new Bugzilla::FlagType($2);
          }
          else {
            require Bugzilla::Flag;
            my $flag = new Bugzilla::Flag($2);
            $flag_type = $flag->type if $flag;
          }
          if ($flag_type) {
            $expanded_fields->{$field_name}->{'flag_type'} = $flag_type;
          }
          else {
            # No need to look for a valid requestee if the flag(type)
            # has been deleted (may occur in race conditions).
            delete $expanded_fields->{$field_name};
            delete $data->{$field_name};
          }
        }
      }
    }
  }
  $fields = $expanded_fields;

  foreach my $field (keys %{$fields}) {
    next unless defined $data->{$field};

    #Concatenate login names, so that we have a common way to handle them.
    my $raw_field;
    if (ref $data->{$field}) {
      $raw_field = join(",", @{$data->{$field}});
    }
    else {
      $raw_field = $data->{$field};
    }
    $raw_field = clean_text($raw_field || '');

    # Now we either split $raw_field by spaces/commas and put the list
    # into @queries, or in the case of fields which only accept single
    # entries, we simply use the verbatim text.
    my @queries;
    if ($fields->{$field}->{'type'} eq 'single') {
      @queries = ($raw_field);

      # We will repopulate it later if a match is found, else it must
      # be set to an empty string so that the field remains defined.
      $data->{$field} = '';
    }
    elsif ($fields->{$field}->{'type'} eq 'multi') {
      @queries = split(/[,;]+/, $raw_field);

      # We will repopulate it later if a match is found, else it must
      # be undefined.
      delete $data->{$field};
    }
    else {
      # bad argument
      ThrowCodeError(
        'bad_arg',
        {
          argument => $fields->{$field}->{'type'},
          function => 'Bugzilla::User::match_field',
        }
      );
    }

    # Tolerate fields that do not exist (in case you specify
    # e.g. the QA contact, and it's currently not in use).
    next unless (defined $raw_field && $raw_field ne '');

    my $limit = 0;
    if ($params->{'maxusermatches'}) {
      $limit = $params->{'maxusermatches'} + 1;
    }

    my @logins;
    for my $query (@queries) {
      $query = trim($query);
      next if $query eq '';

      my $users = match(
        $query,    # match string
        $limit,    # match limit
        1          # exclude_disabled
      );

      # here is where it checks for multiple matches
      if (scalar(@{$users}) == 1) {    # exactly one match
        push(@logins, @{$users}[0]->login);

        # skip confirmation for exact matches
        next if (lc(@{$users}[0]->login) eq lc($query));

        $matches->{$field}->{$query}->{'status'} = 'success';
        $need_confirm = 1 if $params->{'confirmuniqueusermatch'};

      }
      elsif ((scalar(@{$users}) > 1) && ($params->{'maxusermatches'} != 1)) {
        $need_confirm   = 1;
        $match_multiple = 1;
        push(@non_conclusive_fields, $field);

        if ( ($params->{'maxusermatches'})
          && (scalar(@{$users}) > $params->{'maxusermatches'}))
        {
          $matches->{$field}->{$query}->{'status'} = 'trunc';
          pop @{$users};    # take the last one out
        }
        else {
          $matches->{$field}->{$query}->{'status'} = 'success';
        }

      }
      else {
        # everything else fails
        $matchsuccess = 0;    # fail
        push(@non_conclusive_fields, $field);
        $matches->{$field}->{$query}->{'status'} = 'fail';
        $need_confirm = 1;    # confirmation screen shows failures
      }

      $matches->{$field}->{$query}->{'users'} = $users;
    }

    # If no match or more than one match has been found for a field
    # expecting only one match (type eq "single"), we set it back to ''
    # so that the caller of this function can still check whether this
    # field was defined or not (and it was if we came here).
    if ($fields->{$field}->{'type'} eq 'single') {
      $data->{$field} = $logins[0] || '';
    }
    elsif (scalar @logins) {
      $data->{$field} = \@logins;
    }
  }

  my $retval;
  if (!$matchsuccess) {
    $retval = USER_MATCH_FAILED;
  }
  elsif ($match_multiple) {
    $retval = USER_MATCH_MULTIPLE;
  }
  else {
    $retval = USER_MATCH_SUCCESS;
  }

  # Skip confirmation if we were told to, or if we don't need to confirm.
  if ($behavior == MATCH_SKIP_CONFIRM || !$need_confirm) {
    return wantarray ? ($retval, \@non_conclusive_fields) : $retval;
  }

  my $template = Bugzilla->template;
  my $cgi      = Bugzilla->cgi;
  my $vars     = {};

  $vars->{'script'}       = $cgi->url(-relative => 1); # for self-referencing URLs
  $vars->{'fields'}       = $fields;                   # fields being matched
  $vars->{'matches'}      = $matches;                  # matches that were made
  $vars->{'matchsuccess'} = $matchsuccess;             # continue or fail
  $vars->{'matchmultiple'} = $match_multiple;

  print $cgi->header();

  $template->process("global/confirm-user-match.html.tmpl", $vars)
    || ThrowTemplateError($template->error());
  exit;

}

# Changes in some fields automatically trigger events. The field names are
# from the fielddefs table.
our %names_to_events = (
  'resolution'              => EVT_OPENED_CLOSED,
  'keywords'                => EVT_KEYWORD,
  'cc'                      => EVT_CC,
  'bug_type'                => EVT_PROJ_MANAGEMENT,
  'bug_severity'            => EVT_PROJ_MANAGEMENT,
  'priority'                => EVT_PROJ_MANAGEMENT,
  'bug_status'              => EVT_PROJ_MANAGEMENT,
  'target_milestone'        => EVT_PROJ_MANAGEMENT,
  'attachments.description' => EVT_ATTACHMENT_DATA,
  'attachments.mimetype'    => EVT_ATTACHMENT_DATA,
  'attachments.ispatch'     => EVT_ATTACHMENT_DATA,
  'dependson'               => EVT_DEPEND_BLOCK,
  'blocked'                 => EVT_DEPEND_BLOCK,
  'regressed_by'            => EVT_DEPEND_BLOCK,
  'regresses'               => EVT_DEPEND_BLOCK,
  'product'                 => EVT_COMPONENT,
  'component'               => EVT_COMPONENT
);

# Returns true if the user wants mail for a given bug change.
# Note: the "+" signs before the constants suppress bareword quoting.
sub wants_bug_mail {
  my $self = shift;
  my ($bug, $relationship, $fieldDiffs, $comments, $dep_mail, $changer) = @_;

 # is_silent_user is true if the username is mentioned in the param `silent_users`
  return 0 if $changer && $changer->is_silent_user;

  # Make a list of the events which have happened during this bug change,
  # from the point of view of this user.
  my %events;
  foreach my $change (@$fieldDiffs) {
    my $fieldName = $change->{field_name};

    # A change to any of the above fields sets the corresponding event
    if (defined($names_to_events{$fieldName})) {
      $events{$names_to_events{$fieldName}} = 1;
    }
    else {
      # Catch-all for any change not caught by a more specific event
      $events{+EVT_OTHER} = 1;
    }

    # If the user is in a particular role and the value of that role
    # changed, we need the ADDED_REMOVED event.
    if ( ($fieldName eq "assigned_to" && $relationship == REL_ASSIGNEE)
      || ($fieldName eq "qa_contact" && $relationship == REL_QA))
    {
      $events{+EVT_ADDED_REMOVED} = 1;
    }

    if ($fieldName eq "cc") {
      my $login = $self->login;
      my $inold = ($change->{old} =~ /^(.*,\s*)?\Q$login\E(,.*)?$/);
      my $innew = ($change->{new} =~ /^(.*,\s*)?\Q$login\E(,.*)?$/);
      if ($inold != $innew) {
        $events{+EVT_ADDED_REMOVED} = 1;
      }
    }
  }

  if (!$bug->lastdiffed) {

    # Notify about new bugs.
    $events{+EVT_BUG_CREATED} = 1;

    # You role is new if the bug itself is.
    # Only makes sense for the assignee, QA contact and the CC list.
    if ( $relationship == REL_ASSIGNEE
      || $relationship == REL_QA
      || $relationship == REL_CC)
    {
      $events{+EVT_ADDED_REMOVED} = 1;
    }
  }

  if (grep { $_->type == CMT_ATTACHMENT_CREATED } @$comments) {
    $events{+EVT_ATTACHMENT} = 1;
  }
  elsif (defined($$comments[0])) {
    $events{+EVT_COMMENT} = 1;
  }

  # Dependent changed bugmails must have an event to ensure the bugmail is
  # emailed.
  if ($dep_mail) {
    $events{+EVT_DEPEND_BLOCK} = 1;
  }

  my @event_list = keys %events;

  my $wants_mail = $self->wants_mail(\@event_list, $relationship);

  # The negative events are handled separately - they can't be incorporated
  # into the first wants_mail call, because they are of the opposite sense.
  #
  # We do them separately because if _any_ of them are set, we don't want
  # the mail.
  if ($wants_mail && $changer && ($self->id == $changer->id)) {
    $wants_mail &= $self->wants_mail([EVT_CHANGED_BY_ME], $relationship);
  }

  if ($wants_mail && $bug->bug_status eq 'UNCONFIRMED') {
    $wants_mail &= $self->wants_mail([EVT_UNCONFIRMED], $relationship);
  }

  # BMO: add a hook to allow custom bugmail filtering
  Bugzilla::Hook::process(
    "user_wants_mail",
    {
      user         => $self,
      wants_mail   => \$wants_mail,
      bug          => $bug,
      relationship => $relationship,
      fieldDiffs   => $fieldDiffs,
      comments     => $comments,
      dep_mail     => $dep_mail,
      changer      => $changer,
    }
  );

  return $wants_mail;
}

# Returns true if the user wants mail for a given set of events.
sub wants_mail {
  my $self = shift;
  my ($events, $relationship) = @_;

  # Don't send any mail, ever, if account is disabled
  # XXX Temporary Compatibility Change 1 of 2:
  # This code is disabled for the moment to make the behavior like the old
  # system, which sent bugmail to disabled accounts.
  # return 0 if $self->{'disabledtext'};

  # No mail if there are no events
  return 0 if !scalar(@$events);

  # If a relationship isn't given, default to REL_ANY.
  if (!defined($relationship)) {
    $relationship = REL_ANY;
  }

  # Skip DB query if relationship is explicit
  return 1 if $relationship == REL_GLOBAL_WATCHER;

  my $wants_mail = grep { $self->mail_settings->{$relationship}{$_} } @$events;
  return $wants_mail ? 1 : 0;
}

sub mail_settings {
  my $self = shift;
  my $dbh  = Bugzilla->dbh;

  if (!defined $self->{'mail_settings'}) {
    my $data = $dbh->selectall_arrayref(
      'SELECT relationship, event FROM email_setting
                                    WHERE user_id = ?', undef, $self->id
    );
    my %mail;

    # The hash is of the form $mail{$relationship}{$event} = 1.
    $mail{$_->[0]}{$_->[1]} = 1 foreach @$data;

    $self->{'mail_settings'} = \%mail;
  }
  return $self->{'mail_settings'};
}

sub has_audit_entries {
  my $self = shift;
  my $dbh  = Bugzilla->dbh;

  if (!exists $self->{'has_audit_entries'}) {
    $self->{'has_audit_entries'}
      = $dbh->selectrow_array(
      'SELECT 1 FROM audit_log WHERE user_id = ? ' . $dbh->sql_limit(1),
      undef, $self->id);
  }
  return $self->{'has_audit_entries'};
}

sub is_insider {
  my $self = shift;

  if (!defined $self->{'is_insider'}) {
    my $insider_group = Bugzilla->params->{'insidergroup'};
    $self->{'is_insider'}
      = ($insider_group && $self->in_group($insider_group)) ? 1 : 0;
  }
  return $self->{'is_insider'};
}

sub is_global_watcher {
  my $self = shift;

  if (!exists $self->{'is_global_watcher'}) {
    my @watchers = split(/\s*,\s*/, Bugzilla->params->{'globalwatchers'});
    $self->{'is_global_watcher'} = (any { $_ eq $self->login } @watchers) ? 1 : 0;
  }
  return $self->{'is_global_watcher'};
}

sub is_silent_user {
  my $self = shift;

  if (!exists $self->{'is_silent_user'}) {
    my @users = split(/\s*,\s*/, Bugzilla->params->{'silent_users'});
    $self->{'is_silent_user'} = (any { $self->login eq $_ } @users) ? 1 : 0;
  }

  return $self->{'is_silent_user'};
}

sub is_timetracker {
  my $self = shift;

  if (!defined $self->{'is_timetracker'}) {
    my $tt_group = Bugzilla->params->{'timetrackinggroup'};
    $self->{'is_timetracker'} = ($tt_group && $self->in_group($tt_group)) ? 1 : 0;
  }
  return $self->{'is_timetracker'};
}

sub can_tag_comments {
  my $self = shift;

  if (!defined $self->{'can_tag_comments'}) {
    my $group = Bugzilla->params->{'comment_taggers_group'};
    $self->{'can_tag_comments'} = ($group && $self->in_group($group)) ? 1 : 0;
  }
  return $self->{'can_tag_comments'};
}

sub get_userlist {
  my $self = shift;

  return $self->{'userlist'} if defined $self->{'userlist'};

  my $dbh   = Bugzilla->dbh;
  my $query = "SELECT DISTINCT login_name, realname,";
  if (Bugzilla->params->{'usevisibilitygroups'}) {
    $query .= " COUNT(group_id) ";
  }
  else {
    $query .= " 1 ";
  }
  $query .= "FROM profiles ";
  if (Bugzilla->params->{'usevisibilitygroups'}) {
    $query
      .= "LEFT JOIN user_group_map "
      . "ON user_group_map.user_id = userid AND isbless = 0 "
      . "AND group_id IN("
      . join(', ', (-1, @{$self->visible_groups_inherited})) . ")";
  }
  $query .= " WHERE is_enabled = 1 ";
  $query .= $dbh->sql_group_by('userid', 'login_name, realname');

  my $sth = $dbh->prepare($query);
  $sth->execute;

  my @userlist;
  while (my ($login, $name, $visible) = $sth->fetchrow_array) {
    push @userlist,
      {
      login    => $login,
      identity => $name ? "$name <$login>" : $login,
      visible  => $visible,
      };
  }
  @userlist = sort { lc $$a{'identity'} cmp lc $$b{'identity'} } @userlist;

  $self->{'userlist'} = \@userlist;
  return $self->{'userlist'};
}

sub create {
  my ($class, $params) = @_;
  my $dbh = Bugzilla->dbh;

  $dbh->bz_start_transaction();
  $params->{nickname}
    = _generate_nickname($params->{realname}, $params->{login_name}, 0);
  my $email = exists $params->{email} ? delete $params->{email} : $params->{login_name};
  my $user = $class->SUPER::create($params);

  $user->set_email($email);

  # Turn on all email for the new user
  require Bugzilla::BugMail;
  my %relationships = Bugzilla::BugMail::relationships();
  foreach my $rel (keys %relationships) {
    foreach my $event (POS_EVENTS, NEG_EVENTS) {

      # These "exceptions" define the default email preferences.
      #
      # We enable mail unless the change was made by the user, or it's
      # just a CC list addition and the user is not the reporter.
      next if ($event == EVT_CHANGED_BY_ME);
      next if (($event == EVT_CC) && ($rel != REL_REPORTER));

      $dbh->do(
        'INSERT INTO email_setting (user_id, relationship, event)
                      VALUES (?, ?, ?)', undef, ($user->id, $rel, $event)
      );
    }
  }

  foreach my $event (GLOBAL_EVENTS) {
    $dbh->do(
      'INSERT INTO email_setting (user_id, relationship, event)
                  VALUES (?, ?, ?)', undef, ($user->id, REL_ANY, $event)
    );
  }

  $user->derive_regexp_groups();

  # Add the creation date to the profiles_activity table.
  # $who is the user who created the new user account, i.e. either an
  # admin or the new user themselves.
  my $who = Bugzilla->user->id || $user->id;
  my $creation_date_fieldid = get_field_id('creation_ts');

  $dbh->do(
    'INSERT INTO profiles_activity
                          (userid, who, profiles_when, fieldid, newvalue)
                   VALUES (?, ?, NOW(), ?, NOW())', undef,
    ($user->id, $who, $creation_date_fieldid)
  );

  $dbh->bz_commit_transaction();

  # Return the newly created user account.
  return $user;
}

sub check_required_create_fields {
  my ($invocant, $params) = @_;
  my $class = ref($invocant) || $invocant;

  # ensure disabled users also have their email disabled
  $params->{disable_mail} = 1
    if exists $params->{disabledtext}
    && defined($params->{disabledtext})
    && trim($params->{disabledtext}) ne '';
  $class->SUPER::check_required_create_fields($params);
}

###########################
# Account Lockout Methods #
###########################

sub account_is_locked_out {
  my $self           = shift;
  my $login_failures = scalar @{$self->account_ip_login_failures};
  return $login_failures >= MAX_LOGIN_ATTEMPTS ? 1 : 0;
}

sub note_login_failure {
  my $self    = shift;
  my $ip_addr = remote_ip();
  Bugzilla->dbh->do(
    "INSERT INTO login_failure (user_id, ip_addr, login_time)
                       VALUES (?, ?, LOCALTIMESTAMP(0))", undef, $self->id, $ip_addr
  );
  delete $self->{account_ip_login_failures};
}

sub clear_login_failures {
  my $self    = shift;
  my $ip_addr = remote_ip();
  Bugzilla->dbh->do('DELETE FROM login_failure WHERE user_id = ? AND ip_addr = ?',
    undef, $self->id, $ip_addr);
  delete $self->{account_ip_login_failures};
}

sub account_ip_login_failures {
  my $self = shift;
  my $dbh  = Bugzilla->dbh;
  my $time = $dbh->sql_date_math('LOCALTIMESTAMP(0)', '-', LOGIN_LOCKOUT_INTERVAL,
    'MINUTE');
  my $ip_addr = remote_ip();
  $self->{account_ip_login_failures} ||= Bugzilla->dbh->selectall_arrayref(
    "SELECT login_time, ip_addr, user_id FROM login_failure
          WHERE user_id = ? AND login_time > $time
                AND ip_addr = ?
       ORDER BY login_time", {Slice => {}}, $self->id, $ip_addr
  );
  return $self->{account_ip_login_failures};
}

#################
# Email Bounces #
#################

sub bounce_count { $_[0]->{bounce_count}; }

sub bounce_messages {
  my ($self)       = @_;
  my $dbh          = Bugzilla->dbh;
  my $bounce_count = $self->bounce_count;
  return $self->{bounce_messages} ||= $dbh->selectall_arrayref(
    "SELECT " . $dbh->sql_date_format('at_time', '%Y-%m-%d %H:%i') . "
     AS bounce_when, added AS bounce_message FROM audit_log
     WHERE object_id = ? AND class = 'Bugzilla::User' AND field = 'bounce_message'
     ORDER BY at_time DESC LIMIT $bounce_count",
    {Slice => {}},
    $self->id
  );
}

sub set_bounce_count {
  my ($self, $count) = @_;
  $self->set('bounce_count', $count);
  $self->{bounce_count} = $count;
}


###############
# Subroutines #
###############

sub is_available_username {
  my ($username, $old_username) = @_;

  if (login_to_id($username) != 0) {
    return 0;
  }

  my $dbh = Bugzilla->dbh;

  # Reject if the new login is part of an email change which is
  # still in progress
  #
  # substring/locate stuff: bug 165221; this used to use regexes, but that
  # was unsafe and required weird escaping; using substring to pull out
  # the new/old email addresses and sql_position() to find the delimiter (':')
  # is cleaner/safer
  my $eventdata = $dbh->selectrow_array(
    "SELECT eventdata
           FROM tokens
          WHERE (tokentype = 'emailold'
                AND SUBSTRING(eventdata, 1, ("
      . $dbh->sql_position(q{':'}, 'eventdata') . "-  1)) = ?)
             OR (tokentype = 'emailnew'
                AND SUBSTRING(eventdata, ("
      . $dbh->sql_position(q{':'}, 'eventdata')
      . "+ 1), LENGTH(eventdata)) = ?)",
    undef, ($username, $username)
  );

  if ($eventdata) {

    # Allow thru owner of token
    if ($old_username && ($eventdata eq "$old_username:$username")) {
      return 1;
    }
    return 0;
  }

  return 1;
}

sub check_account_creation_enabled {
  my $self = shift;

  # If we're using e.g. LDAP for login, then we can't create a new account.
  $self->authorizer->user_can_create_account
    || ThrowUserError('auth_cant_create_account');

  Bugzilla->params->{'createemailregexp'}
    || ThrowUserError('account_creation_disabled');
}

sub check_and_send_account_creation_confirmation {
  my ($self, $login, $email) = @_;

  $login = $self->check_login_name_for_creation($login);
  $email = Bugzilla::User::Email->check_email_for_creation($email);
  my $creation_regexp = Bugzilla->params->{'createemailregexp'};

  if ($email !~ /$creation_regexp/i) {
    ThrowUserError('account_creation_restricted');
  }

  # BMO - add a hook to allow extra validation prior to account creation.
  Bugzilla::Hook::process("user_verify_login", {login => $login, email => $email});

  # Create and send a token for this new account.
  require Bugzilla::Token;
  Bugzilla::Token::issue_new_user_account_token($login, $email);
}

# This is used in a few performance-critical areas where we don't want to
# do check() and pull all the user data from the database.
sub login_to_id {
  my ($login, $throw_error) = @_;
  my $dbh = Bugzilla->dbh;
  my $cache = Bugzilla->request_cache->{user_login_to_id} ||= {};

  # We cache lookups because this function showed up as taking up a
  # significant amount of time in profiles of xt/search.t. However,
  # for users that don't exist, we re-do the check every time, because
  # otherwise we break is_available_username.
  my $user_id;
  if (defined $cache->{$login}) {
    $user_id = $cache->{$login};
  }
  else {
    $user_id = $dbh->selectrow_array(
      "SELECT userid FROM profiles
              WHERE " . $dbh->sql_istrcmp('login_name', '?'), undef, $login
    );
    $cache->{$login} = $user_id;
  }

  if ($user_id) {
    return $user_id;
  }
  elsif ($throw_error) {
    ThrowUserError('invalid_username', {name => $login});
  }
  else {
    return 0;
  }
}

sub user_id_to_login {
  my $user_id = shift;
  my $dbh     = Bugzilla->dbh;

  return '' unless ($user_id && detaint_natural($user_id));

  my $login = $dbh->selectrow_array(
    'SELECT login_name FROM profiles
                                       WHERE userid = ?', undef, $user_id
  );
  return $login || '';
}

1;

__END__

=head1 NAME

Bugzilla::User - Object for a Bugzilla user

=head1 SYNOPSIS

  use Bugzilla::User;

  my $user = new Bugzilla::User($id);

  my @get_selectable_classifications =
      $user->get_selectable_classifications;

  # Class Functions
  $user = Bugzilla::User->create({
      login_name    => $username,
      realname      => $realname,
      cryptpassword => $plaintext_password,
      disabledtext  => $disabledtext,
      disable_mail  => 0});

=head1 DESCRIPTION

This package handles Bugzilla users. Data obtained from here is read-only;
there is currently no way to modify a user from this package.

Note that the currently logged in user (if any) is available via
L<Bugzilla-E<gt>user|Bugzilla/"user">.

C<Bugzilla::User> is an implementation of L<Bugzilla::Object>, and thus
provides all the methods of L<Bugzilla::Object> in addition to the
methods listed below.

=head1 CONSTANTS

=over

=item C<USER_MATCH_MULTIPLE>

Returned by C<match_field()> when at least one field matched more than
one user, but no matches failed.

=item C<USER_MATCH_FAILED>

Returned by C<match_field()> when at least one field failed to match
anything.

=item C<USER_MATCH_SUCCESS>

Returned by C<match_field()> when all fields successfully matched only one
user.

=item C<MATCH_SKIP_CONFIRM>

Passed in to match_field to tell match_field to never display a
confirmation screen.

=back

=head1 METHODS

=head2 Constructors

=over

=item C<super_user>

Returns a user who is in all groups, but who does not really exist in the
database. Used for non-web scripts like L<checksetup> that need to make
database changes and so on.

=back

=head2 Saved and Shared Queries

=over

=item C<queries>

Returns an arrayref of the user's own saved queries, sorted by name. The
array contains L<Bugzilla::Search::Saved> objects.

=item C<queries_subscribed>

Returns an arrayref of shared queries that the user has subscribed to.
That is, these are shared queries that the user sees in their footer.
This array contains L<Bugzilla::Search::Saved> objects.

=item C<queries_available>

Returns an arrayref of all queries to which the user could possibly
subscribe. This includes the contents of L</queries_subscribed>.
An array of L<Bugzilla::Search::Saved> objects.

=item C<flush_queries_cache>

Some code modifies the set of stored queries. Because C<Bugzilla::User> does
not handle these modifications, but does cache the result of calling C<queries>
internally, such code must call this method to flush the cached result.

=item C<queryshare_groups>

An arrayref of group ids. The user can share their own queries with these
groups.

=item C<tags>

Returns a hashref with tag IDs as key, and a hashref with tag 'id',
'name' and 'bug_count' as value.

=item C<bugs_ignored>

Returns an array of hashrefs containing information about bugs currently
being ignored by the user.

Each hashref contains the following information:

=over

=item C<id>

C<int> The id of the bug.

=item C<status>

C<string> The current status of the bug.

=item C<summary>

C<string> The current summary of the bug.

=back

=item C<is_bug_ignored>

Returns true if the user does not want email notifications for the
specified bug ID, else returns false.

=back

=head2 Saved Recent Bug Lists

=over

=item C<recent_searches>

Returns an arrayref of L<Bugzilla::Search::Recent> objects
containing the user's recent searches.

=item C<recent_search_containing(bug_id)>

Returns a L<Bugzilla::Search::Recent> object that contains the most recent
search by the user for the specified bug id. Returns undef if no match is found.

=item C<recent_search_for(bug)>

Returns a L<Bugzilla::Search::Recent> object that contains a search by the
user. Uses the list_id of the current loaded page, or the referrer page, and
the bug id if that fails. Finally it will check the BUGLIST cookie, and create
an object based on that, or undef if it does not exist.

=item C<save_last_search>

Saves the users most recent search in the database if logged in, or in the
BUGLIST cookie if not logged in. Parameters are bug_ids, order, vars and
list_id.

=back

=head2 Account Lockout

=over

=item C<account_is_locked_out>

Returns C<1> if the account has failed to log in too many times recently,
and thus is locked out for a period of time. Returns C<0> otherwise.

=item C<account_ip_login_failures>

Returns an arrayref of hashrefs, that contains information about the recent
times that this account has failed to log in from the current remote IP.
The hashes contain C<ip_addr>, C<login_time>, and C<user_id>.

=item C<note_login_failure>

This notes that this account has failed to log in, and stores the fact
in the database. The storing happens immediately, it does not wait for
you to call C<update>.

=item C<set_email_enabled>

C<bool> - Sets C<disable_mail> to the inverse of the boolean provided.

=back

=head2 Other Methods

=over

=item C<id>

Returns the userid for this user.

=item C<login>

Returns the login name for this user.

=item C<email>

Returns the user's email address. Currently this is the same value as the
login.

=item C<name>

Returns the 'real' name for this user, if any.

=item C<showmybugslink>

Returns C<1> if the user has set their preference to show the 'My Bugs' link in
the page footer, and C<0> otherwise.

=item C<identity>

Returns a string for the identity of the user. This will be of the form
C<name E<lt>emailE<gt>> if the user has specified a name, and C<email>
otherwise.

=item C<nick>

Returns a user "nickname" -- i.e. a shorter, not-necessarily-unique name by
which to identify the user. Currently the part of the user's email address
before the at sign (@), but that could change, especially if we implement
usernames not dependent on email address.

=item C<authorizer>

This is the L<Bugzilla::Auth> object that the User logged in with.
If the user hasn't logged in yet, a new, empty Bugzilla::Auth() object is
returned.

=item C<set_authorizer($authorizer)>

Sets the L<Bugzilla::Auth> object to be returned by C<authorizer()>.
Should only be called by C<Bugzilla::Auth::login>, for the most part.

=item C<disabledtext>

Returns the disable text of the user, if any.

=item C<settings>

Returns a hash of hashes which holds the user's settings. The first key is
the name of the setting, as found in setting.name. The second key is one of:
is_enabled     - true if the user is allowed to set the preference themselves;
                 false to force the site defaults
                 for themselves or must accept the global site default value
default_value  - the global site default for this setting
value          - the value of this setting for this user. Will be the same
                 as the default_value if the user is not logged in, or if
                 is_default is true.
is_default     - a boolean to indicate whether the user has chosen to make
                 a preference for themself or use the site default.

=item C<setting(name)>

Returns the value for the specified setting.

=item C<timezone>

Returns the timezone used to display dates and times to the user,
as a DateTime::TimeZone object.

=item C<groups>

Returns an arrayref of L<Bugzilla::Group> objects representing
groups that this user is a member of.

=item C<groups_as_string>

Returns a string containing a comma-separated list of numeric group ids.  If
the user is not a member of any groups, returns "-1". This is most often used
within an SQL IN() function.

=item C<groups_in_sql>

This returns an C<IN> clause for SQL, containing either all of the groups
the user is in, or C<-1> if the user is in no groups. This takes one
argument--the name of the SQL field that should be on the left-hand-side
of the C<IN> statement, which defaults to C<group_id> if not specified.

=item C<in_group($group_name, $product_id)>

Determines whether or not a user is in the given group by name.
If $product_id is given, it also checks for local privileges for
this product.

=item C<in_group_id>

Determines whether or not a user is in the given group by id.

=item C<bless_groups>

Returns an arrayref of L<Bugzilla::Group> objects.

The arrayref consists of the groups the user can bless, taking into account
that having admin permissions means that you can bless all groups, and
that you need to be able to see a group in order to bless it.

=item C<get_products_by_permission($group)>

Returns a list of product objects for which the user has $group privileges
and which they can access.
$group must be one of the groups defined in PER_PRODUCT_PRIVILEGES.

=item C<can_see_user(user)>

Returns 1 if the specified user account exists and is visible to the user,
0 otherwise.

=item C<can_edit_product(prod_id)>

Determines if, given a product id, the user can edit bugs in this product
at all.

=item C<can_see_bug(bug_id)>

Determines if the user can see the specified bug.

=item C<can_see_product(product_name)>

Returns 1 if the user can access the specified product, and 0 if the user
should not be aware of the existence of the product.

=item C<derive_regexp_groups>

Bugzilla allows for group inheritance. When data about the user (or any of the
groups) changes, the database must be updated. Handling updated groups is taken
care of by the constructor. However, when updating the email address, the
user may be placed into different groups, based on a new email regexp. This
method should be called in such a case to force reresolution of these groups.

=item C<clear_product_cache>

Clears the stored values for L</get_selectable_products>,
L</get_enterable_products>, etc. so that their data will be read from
the database again. Used mostly by L<Bugzilla::Product>.

=item C<get_selectable_products>

 Description: Returns all products the user is allowed to access. This list
              is restricted to some given classification if $classification_id
              is given.

 Params:      $classification_id - (optional) The ID of the classification
                                   the products belong to.

 Returns:     An array of product objects, sorted by the product name.

=item C<get_selectable_classifications>

 Description: Returns all classifications containing at least one product
              the user is allowed to view.

 Params:      none

 Returns:     An array of Bugzilla::Classification objects, sorted by
              the classification name.

=item C<can_enter_product($product_name, $warn)>

 Description: Returns a product object if the user can enter bugs into the
              specified product.
              If the user cannot enter bugs into the product, the behavior of
              this method depends on the value of $warn:
              - if $warn is false (or not given), a 'false' value is returned;
              - if $warn is true, an error is thrown.

 Params:      $product_name - a product name.
              $warn         - optional parameter, indicating whether an error
                              must be thrown if the user cannot enter bugs
                              into the specified product.

 Returns:     A product object if the user can enter bugs into the product,
              0 if the user cannot enter bugs into the product and if $warn
              is false (an error is thrown if $warn is true).

=item C<get_enterable_products>

 Description: Returns an array of product objects into which the user is
              allowed to enter bugs.

 Params:      none

 Returns:     an array of product objects.

=item C<can_access_product($product)>

Returns 1 if the user can search or enter bugs into the specified product
(either a L<Bugzilla::Product> or a product name), and 0 if the user should
not be aware of the existence of the product.

=item C<get_accessible_products>

 Description: Returns an array of product objects the user can search
              or enter bugs against.

 Params:      none

 Returns:     an array of product objects.

=item C<check_can_admin_product($product_name)>

 Description: Checks whether the user is allowed to administrate the product.

 Params:      $product_name - a product name.

 Returns:     On success, a product object. On failure, an error is thrown.

=item C<check_can_admin_flagtype($flagtype_id)>

 Description: Checks whether the user is allowed to edit properties of the flag type.
              If the flag type is also used by some products for which the user
              hasn't editcomponents privs, then the user is only allowed to edit
              the inclusion and exclusion lists for products they can administrate.

 Params:      $flagtype_id - a flag type ID.

 Returns:     On success, a flag type object. On failure, an error is thrown.
              In list context, a boolean indicating whether the user can edit
              all properties of the flag type is also returned. The boolean
              is false if the user can only edit the inclusion and exclusions
              lists.

=item C<can_request_flag($flag_type)>

 Description: Checks whether the user can request flags of the given type.

 Params:      $flag_type - a Bugzilla::FlagType object.

 Returns:     1 if the user can request flags of the given type,
              0 otherwise.

=item C<can_set_flag($flag_type)>

 Description: Checks whether the user can set flags of the given type.

 Params:      $flag_type - a Bugzilla::FlagType object.

 Returns:     1 if the user can set flags of the given type,
              0 otherwise.

=item C<get_userlist>

Returns a reference to an array of users.  The array is populated with hashrefs
containing the login, identity and visibility.  Users that are not visible to this
user will have 'visible' set to zero.

=item C<visible_groups_inherited>

Returns a list of all groups whose members should be visible to this user.
Since this list is flattened already, there is no need for all users to
be have derived groups up-to-date to select the users meeting this criteria.

=item C<visible_groups_direct>

Returns a list of groups that the user is aware of.

=item C<visible_groups_as_string>

Returns the result of C<visible_groups_inherited> as a string (a comma-separated
list).

=item C<product_responsibilities>

Retrieve user's product responsibilities as a list of component objects.
Each object is a component the user has a responsibility for.

=item C<can_bless>

When called with no arguments:
Returns C<1> if the user can bless at least one group, returns C<0> otherwise.

When called with one argument:
Returns C<1> if the user can bless the group with that id, returns
C<0> otherwise.

=item C<wants_bug_mail>

Returns true if the user wants mail for a given bug change.

=item C<wants_mail>

Returns true if the user wants mail for a given set of events. This method is
more general than C<wants_bug_mail>, allowing you to check e.g. permissions
for flag mail.

=item C<is_insider>

Returns true if the user can access private comments and attachments,
i.e. if the 'insidergroup' parameter is set and the user belongs to this group.

=item C<is_global_watcher>

Returns true if the user is a global watcher,
i.e. if the 'globalwatchers' parameter contains the user.

=item C<can_tag_comments>

Returns true if the user can attach tags to comments.
i.e. if the 'comment_taggers_group' parameter is set and the user belongs to
this group.

=item C<last_visited>

Returns an arrayref L<Bugzilla::BugUserLastVisit> objects.

=item C<is_involved_in_bug($bug)>

Returns true if any of the following conditions are met, false otherwise.

=over

=item *

User is the assignee of the bug

=item *

User is the reporter of the bug

=item *

User is the QA contact of the bug (if Bugzilla is configured to use a QA
contact)

=item *

User is in the cc list for the bug.

=back

=back

=head1 CLASS FUNCTIONS

These are functions that are not called on a User object, but instead are
called "statically," just like a normal procedural function.

=over 4

=item C<create>

The same as L<Bugzilla::Object/create>.

Params: login_name - B<Required> The login name for the new user.
        realname - The full name for the new user.
        cryptpassword  - B<Required> The password for the new user.
            Even though the name says "crypt", you should just specify
            a plain-text password. If you specify '*', the user will not
            be able to log in using DB authentication.
        disabledtext - The disable-text for the new user. If given, the user
            will be disabled, meaning they cannot log in. Defaults to an
            empty string.
        disable_mail - If 1, bug-related mail will not be  sent to this user;
            if 0, mail will be sent depending on the user's  email preferences.
            disable_mail is always 1 for disabled users.

=item C<check>

Takes a username as its only argument. Throws an error if there is no
user with that username. Returns a C<Bugzilla::User> object.

=item C<check_account_creation_enabled>

Checks that users can create new user accounts, and throws an error
if user creation is disabled.

=item C<check_and_send_account_creation_confirmation($login)>

If the user request for a new account passes validation checks, an email
is sent to this user for confirmation. Otherwise an error is thrown
indicating why the request has been rejected.

=item C<is_available_username>

Returns a boolean indicating whether or not the supplied username is
already taken in Bugzilla.

Params: $username (scalar, string) - The full login name of the username
            that you are checking.
        $old_username (scalar, string) - If you are checking an email-change
            token, insert the "old" username that the user is changing from,
            here. Then, as long as it's the right user for that token, they
            can change their username to $username. (That is, this function
            will return a boolean true value).

=item C<login_to_id($login, $throw_error)>

Takes a login name of a Bugzilla user and changes that into a numeric
ID for that user. This ID can then be passed to Bugzilla::User::new to
create a new user.

If no valid user exists with that login name, then the function returns 0.
However, if $throw_error is set, the function will throw a user error
instead of returning.

This function can also be used when you want to just find out the userid
of a user, but you don't want the full weight of Bugzilla::User.

However, consider using a Bugzilla::User object instead of this function
if you need more information about the user than just their ID.

=item C<user_id_to_login($user_id)>

Returns the login name of the user account for the given user ID. If no
valid user ID is given or the user has no entry in the profiles table,
we return an empty string.

=item C<match_field($data, $fields, $behavior)>

=over

=item B<Description>

Wrapper for the C<match()> function.

=item B<Params>

=over

=item C<$fields> - A hashref with field names as keys and a hash as values.
Each hash is of the form { 'type' => 'single|multi' }, which specifies
whether the field can take a single login name only or several.

=item C<$data> (optional) - A hashref with field names as keys and field values
as values. If undefined, C<Bugzilla-E<gt>input_params> is used.

=item C<$behavior> (optional) - If set to C<MATCH_SKIP_CONFIRM>, no confirmation
screen is displayed. In that case, the fields which don't match a unique user
are left undefined. If not set, a confirmation screen is displayed if at
least one field doesn't match any login name or match more than one.

=back

=item B<Returns>

If the third parameter is set to C<MATCH_SKIP_CONFIRM>, the function returns
either C<USER_MATCH_SUCCESS> if all fields can be set unambiguously,
C<USER_MATCH_FAILED> if at least one field doesn't match any user account,
or C<USER_MATCH_MULTIPLE> if some fields match more than one user account.

If the third parameter is not set, then if all fields could be set
unambiguously, nothing is returned, else a confirmation page is displayed.

=item B<Note>

This function must be called early in a script, before anything external
is done with the data.

=back

=back

=head1 SEE ALSO

L<Bugzilla|Bugzilla>
