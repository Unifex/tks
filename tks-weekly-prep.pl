#!/usr/bin/perl

# Generate a boilerplate file for tks.
# Stick this in cron, to run early on a Monday morning.
#   tks-prep > $HOME/tks-$(date +\%Y-\%m-\%d)
#
# You can put the following config into $HOME/.tks-preprc:
#
# username: $wrms_username
# password: $wrms_password

use v5.10;
use strict;
use warnings;

use LWP::UserAgent;
use JSON::XS;
use URI;
use Getopt::Long;
use Scriptalicious;
use DateTime;

my %conf = (
  weeks_look_back => '4',
);


getopt getconf(
  'username|u=s'  => \$conf{'username'},
  'password|p=s'  => \$conf{'password'},
  'look_back|l=i' => \$conf{'weeks_look_back'},
);

if (! $conf{'username'}) {
  $conf{'username'} = prompt_string("WRMS Username: ");
}
if (! $conf{'password'}) {
  $conf{'password'} = prompt_passwd("WRMS Password: ");
  print "\n";
}

for my $field (qw/username password/) {
  die "No $field" unless defined $conf{$field} && $conf{$field} =~ /^\s*/;
}

die "Weeks look back must be a number"
  unless $conf{'weeks_look_back'} =~ /^\d+$/;


my $ua = LWP::UserAgent->new( cookie_jar => {} );

# first login to get the auth cookie
my $login_url = 'https://wrms.catalyst.net.nz/api2/login';

# you may wish to hard code this
my %LOGIN_FORM = (
    username => $conf{'username'},
    password => $conf{'password'},
);

my $login_response = $ua->post( $login_url, \%LOGIN_FORM );

die $login_response->status_line unless $login_response->is_success;

# craft the query, you may wish to modify this
my %query = (
    report_type          => 'timesheet',
    page_size            => 200,
    page_no              => 1,
    display_fields       => 'request_id,brief,organisation_name,hours_sum',
    order_by             => 'organisation_name',
    order_direction      => 'asc',
    worker               => 'MY_USER_ID',
    created_date         => 'w-' . $conf{'weeks_look_back'} . ":",
);

my $uri = URI->new("https://wrms.catalyst.net.nz/api2/report");
$uri->query_form(\%query);

# get the response
my $response = $ua->get($uri);

die $response->status_line unless $response->is_success;
my $data = decode_json($response->decoded_content);

#use Data::Dumper;
#dump($data);

# Work out the maximum length of some fields we're interested in,
# and allow us to sort by org.
my %lengths = (
    organisation_name => 0,
    request_id        => 0,
);
my %timesheets;
foreach my $ts (@{$data->{response}{results}}) {
    for my $field (qw/request_id organisation_name/) {
        $lengths{$field} = length($ts->{$field})
            if length($ts->{$field}) > $lengths{$field};
    }

    $timesheets{$ts->{organisation_name}}{$ts->{request_id}} = $ts;
}


my $local_tz = DateTime::TimeZone->new( name => 'local' );
my $start_of_week = DateTime->today( time_zone => $local_tz )->truncate( to => 'week' );

for ( 0..6 ) {
  say $start_of_week->clone()->add( days => $_ )->strftime("%Y-%m-%d # %A"), "\n";
}

say "# Work requests you've used in the last " . $conf{'weeks_look_back'} . " weeks.";
for my $org (sort keys %timesheets) {
    say "#\n# $org\n#";
    for my $wr_id (sort { $a <=> $b } keys %{ $timesheets{$org} }) {
        my $ts = $timesheets{$org}{$wr_id};
        say '# WR ' . $wr_id . padding($ts, 'request_id') . $ts->{brief};
    }
}

# Nicely line up columns.
sub padding {
  my ($ts, $field) = @_;

  return ' ' x (2 + $lengths{$field} - length($ts->{$field}));
}

  

#https://wrms.catalyst.net.nz/api2/report?created_date=w-4%3A&worker=MY_USER_ID&report_type=timesheet&page_size=200&page_no=1&display_fields=request_id%2Cbrief%2Chours_sum&order_by=request_id&order_direction=asc
