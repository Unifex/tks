# Copyright (C) 2009 Catalyst IT Ltd (http://www.catalyst.net.nz)
#
# This file is distributed under the same terms as tks itself.
package TKS::Backend::WRMSWeb;

use strict;
use warnings;
use base 'TKS::Backend';
use Date::Calc;
use WWW::Mechanize;
use XML::LibXML;
use JSON;
use POSIX;
use TKS::Timesheet;
use URI;
use Term::ProgressBar;
use POSIX;

$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

sub user_agent_string {
    my ($self) = @_;

    my $tks_version = $main::VERSION || 'unknown';
    my $user_agent_string = "tks/$tks_version";

    my $user_no = $self->instance_config('wrms_user_no');

    if ( $user_no ) {
        $user_agent_string .= " user_no=$user_no";
    }

    return $user_agent_string;
}

sub init {
    my ($self) = @_;

    my $mech = $self->{mech} = WWW::Mechanize->new( agent => $self->user_agent_string );
    $mech->quiet(1);
    $self->{parser} = XML::LibXML->new();
    $self->{parser}->recover(1);
    $self->{wrms_user_no} = $self->instance_config('wrms_user_no');
    my $session_id = $self->instance_config('wrms_cookie');
    if ( $session_id ) {
        my $uri = URI->new($self->baseurl);
        my $cookie_host = $uri->host eq 'localhost' ? 'localhost.local' : $uri->host;
        $self->{mech}->cookie_jar->set_cookie(0, 'sid', $session_id, '/', $cookie_host);
    }
}

sub fetch_page {
    my ($self, $url) = @_;

    my $mech = $self->{mech};

    eval { $mech->get(URI->new_abs($url, $self->baseurl)); };

    if ( $mech->status == 403 ) {
        $mech->get($self->baseurl);
        if ( $mech->form_with_fields('username', 'password') ) {
            $self->_login;
            $mech->get(URI->new_abs($url, $self->baseurl));
        }
        else {
            die "Couldn't find login form";
        }
    }

    unless ( $mech->status == 200 ) {
        die "Got non-200 (" . $mech->status . ") status from mechanize: $@";
    }

    if ( $mech->form_with_fields('username', 'password') ) {
        $self->_login;
    }
}

sub _login {
    my ($self) = @_;

    my $mech = $self->{mech};

    my $username = $self->instance_config('username');
    my $password = $self->instance_config('password');

    if ( -t STDERR and ( not $username or not $password ) ) {
        print STDERR "Please enter details for " . $self->baseurl . "\n";
        $username ||= $self->read_line('username: ');
        $password ||= $self->read_password('password: ');
    }

    unless ( $username and $password ) {
        die "Missing username and/or password";
    }

    print STDERR "Attemping login to WRMS as $username\n";

    # Check for login form
    unless (
        defined $mech->current_form()
        and defined $mech->current_form()->find_input('username')
        and defined $mech->current_form()->find_input('password')
    ) {
        die "Couldn't find WRMS login form at " . $self->baseurl . ". HTTP status was: " . $mech->status;
    }

    # Login
    $mech->submit_form(
        fields => {
            username => $username,
            password => $password,
        },
    );

    # Attempt to determine if it worked or not
    my $dom = $self->parse_page;

    my @messages = map { $_->textContent } $dom->findnodes('//ul[@class="messages"]/li');
    if ( @messages ) {
        die "Login failed\n" . join("\n", map { " - $_" } @messages) . "\nStopped at ";
    }

    my ($uncharged_work_link) = grep { $_->textContent eq 'My Uncharged Work' } $dom->findnodes('//a');
    unless ( $uncharged_work_link and $uncharged_work_link->getAttribute('href') =~ /user_no=(\d+)/ ) {
        die "Couldn't determine WRMS user_no";
    }

    $self->{wrms_user_no} = $1;
    $self->instance_config_set('wrms_user_no', $self->{wrms_user_no});
    $self->{mech}->agent($self->user_agent_string);

    $mech->cookie_jar->scan(sub {
        my (undef, $key, $value, undef, $domain) = @_;
        $domain =~ s/^localhost.local$/localhost/;
        return unless $key eq 'sid';
        return unless $self->baseurl =~ m{\Q$domain\E};
        $self->instance_config_set('wrms_cookie', $value);
    });
}

sub baseurl {
    my ($self) = @_;

    my $site     = $self->instance_config('site');
    $site ||= 'https://wrms.catalyst.net.nz/';

    $site .= '/' unless $site =~ m{ / \z }xms;

    return $site;
}

sub user_search {
    my ($self, $search) = @_;

    unless ( $self->{user_cache} ) {
        $self->{user_cache} = [];
        my $org = $self->instance_config('org');
        $org ||= 37; # Catalyst IT (NZ)
        $org = undef if $org eq 'any';

        $self->fetch_page('usrsearch.php'.($org ? '?org_code='.$org : ''));

        my $dom = $self->parse_page;

        my ($table) = grep { $_->findnodes('./tr[1]/*')->size == ($org ? 5 : 6) } $dom->findnodes('//table');
        die "Couldn't find user list table" unless $table;

        my @users;
        foreach my $row ( $table->findnodes('./tr') ) {
            my @data = map { $_->textContent } $row->findnodes('./td');

            next unless $data[$org ? 3 : 4] and $data[$org ? 3 : 4] =~ m{ (\d\d)/(\d\d)/(\d\d\d\d) }xms;
            next unless $row->findvalue('./td[1]//a/@href') =~ m{ \b user_no = (\d+) \b }xms;

            push @{$self->{user_cache}}, {
                user_no   => $1,
                username => $data[0],
                fullname => $data[1],
                email    => $data[$org ? 2 : 3],
            };
        }
    }

    my @matches = grep { $_->{username} eq $search } @{$self->{user_cache}};

    unless ( @matches ) {
        @matches = grep {
            $_->{username} =~ m{ \Q$search\E }ixms
            or $_->{fullname} =~ m{ \Q$search\E }ixms
            or $_->{email} =~ m{ \Q$search\E }ixms
        } @{$self->{user_cache}};
    }

    die "No matches found for search '$search'" unless @matches;
    die "Multiple matches found for search '$search'\n"
        . join("\n", map { "$_->{username} - $_->{fullname} ($_->{email})" } @matches)
        . "\n" unless @matches == 1;

    print STDERR "Matched user: $matches[0]->{username} - $matches[0]->{fullname} <$matches[0]->{email}>\n";
    return $matches[0]->{user_no} if @matches;
}

sub get_timesheet_scrape {
    my ($self, $dates, $user) = @_;

    $dates = TKS::Date->new($dates);

    my $timesheet = TKS::Timesheet->new();

    if ( $user and $user !~ m{ \A \d+ \z }xms ) {
        $user = $self->user_search($user);
    }

    $user ||= $self->{wrms_user_no};

    unless ( $user ) {
        # grab the homepage and log in (to get the wrms user number)
        $self->fetch_page('');
        $user = $self->{wrms_user_no};
    }

    $self->fetch_page("form.php?f=timelist&user_no=$user&uncharged=1&from_date=" . $dates->mindate . "&to_date=" . $dates->maxdate);

    my $dom = $self->parse_page;
    my $timelistfields = $self->instance_config('timelistfields');
    $timelistfields ||= 14;

    my ($table) = grep { $_->findnodes('./tr[1]/*')->size == $timelistfields } $dom->findnodes('//table');

    die "Couldn't find data table" unless $table;

    foreach my $row ( $table->findnodes('./tr') ) {
        my @data = map { $_->textContent } $row->findnodes('./td');

	my $timelistorgoffset = $self->instance_config('timelistorgoffset');
        $timelistorgoffset ||= 0;

        next unless $data[3 + $timelistorgoffset] and $data[3 + $timelistorgoffset] =~ m{ \A (\d\d)/(\d\d)/(\d\d\d\d) \z }xms;

        my $entry = {
            date         => "$3-$2-$1",
            request      => $data[2 + $timelistorgoffset],
            comment      => $data[7 + $timelistorgoffset],
            time         => $data[4 + $timelistorgoffset],
            needs_review => $data[8 + $timelistorgoffset],
        };

        next unless $dates->contains($entry->{date});

        unless ( $entry->{time} =~ m{ \A ( [\d.]+ ) \s hours \z }xms ) {
            die "Can't parse hours from time '$entry->{time}'";
        }
        $entry->{time} = $1;

        $entry->{needs_review} = $entry->{needs_review} =~ m{ review }ixms ? 1 : 0;

        $timesheet->addentry(TKS::Entry->new($entry));
    }

    return $timesheet;
}

sub get_timesheet {
    my ($self, $dates, $user) = @_;

    if ( $user ) {
        return $self->get_timesheet_scrape($dates, $user);
    }

    $dates = TKS::Date->new($dates);

    my $timesheet = TKS::Timesheet->new();

    my %dates_to_fetch;
    foreach my $date ( $dates->dates ) {
        die "Couldn't parse date '$date'" unless $date =~ m{ \A (\d\d\d\d)-(\d\d)-(\d\d) \z }xms;
        my $week_start = mktime(0, 0, 0, $3, $2 - 1, $1 - 1900);
        $week_start = sprintf('%04d-%02d-%02d', Date::Calc::Add_Delta_Days($1, $2, $3, -strftime('%u',localtime($week_start))+1));
        push @{$dates_to_fetch{$week_start}}, $date;
    }

    foreach my $date ( keys %dates_to_fetch ) {
        $self->fetch_page('api.php/times/week/' . $date);
        my $entries = eval { from_json($self->{mech}->content); };
        if ( $@ ) {
            die "Couldn't parse api response: $@";
        }
        unless ( $entries and ref $entries eq 'ARRAY' ) {
            die "Unexpected response from api";
        }
        foreach my $entry ( @{$entries} ) {
            next unless grep { $entry->{date} eq $_ } @{$dates_to_fetch{$date}};

            $timesheet->addentry(TKS::Entry->new(
                date         => $entry->{date},
                request      => $entry->{request_id},
                comment      => $entry->{work_description},
                time         => $entry->{hours},
                needs_review => $entry->{needs_review} ? 1 : 0,
            ));
        }
    }

    return $timesheet;
}

sub add_timesheet {
    my ($self, $timesheet, $show_progress) = @_;

    foreach my $entry ( $timesheet->entries ) {
        die 'Invalid request "' . $entry->request . '"' unless $self->valid_request($entry->request);
    }

    if ( $show_progress ) {
        print STDERR "Fetching existing entries...\n";
    }

    my $existing = $self->get_timesheet($timesheet->dates);
    $existing->addtimesheet($timesheet);

    if ( $show_progress ) {
        $show_progress = Term::ProgressBar->new({
            count => scalar($existing->compact->entries),
            name  => 'Adding timesheets',
            ETA   => 'linear',
        });
    }

    my $count = 0;
    foreach my $entry ( sort { $a->time <=> $b->time } $existing->compact->entries ) {
        my $comment = $entry->comment;
        $comment =~ s/[\x80-\xff]+/??/g;
        my $data = to_json({
            work_on          => $entry->date,
            request_id       => $entry->request,
            work_description => $comment,
            hours            => sprintf('%.2f', $entry->time),
            needs_review     => $entry->needs_review,
        });

        #print "Post: $data\n";
        #next;

        $self->{mech}->post($self->baseurl . 'api.php/times/record', Content => $data);
        # method returns "old" hours
        unless ( $self->{mech}->content =~ m{ \A [\d.]+ \z }xms ) {
            die "Error committing time for request " . $entry->request . ": '" . $self->{mech}->content . "'";
        }
        if ( $show_progress ) {
            $show_progress->update(++$count);
        }
    }
    if ( $show_progress ) {
        print STDERR "Successfully committed $count changes\n";
    }
}

sub valid_request {
    my ($self, $request) = @_;

    return 1 if $request =~ m{ \A \d+ \z }xms;

    return
}

sub parse_page {
    my ($self) = @_;

    my $dom;
    {
        local *STDERR;
        open STDERR, '>', '/dev/null';

        $dom = eval { $self->{parser}->parse_html_string($self->{mech}->content()) };
    }

    return $dom if defined $dom;

    die q{XML::LibXML couldn't parse '} . $self->{mech}->uri . q{': } . $@;
}

sub post_comment {
    my ($self, $timesheet) = @_;

    my $output = '';

    return '' unless grep { $_->request ne '-' } $timesheet->entries;

    my $uri = URI->new('http://wrms.abelard.wgtn.cat-it.co.nz/json');
    $uri->query_form({
        q => 'request_id:(' . join(' OR ', map { $_->request } grep { $_->request ne '-' } $timesheet->entries) . ')',
        searchadvanced => 1,
    });

    $self->fetch_page($uri);
    my $data = eval { from_json($self->{mech}->content); };

    if ( $data and $data->{numFound} > 0 ) {
        foreach my $wr ( sort { $a->{request_id} <=> $b->{request_id} } @{$data->{results}} ) {
            $output .= sprintf
                "# WR #%d [%s] %s\n",
                $wr->{request_id},
                $wr->{system_code_facet}[0],
                $wr->{brief},
            ;
        }
    }

    return $output;
}


1;
