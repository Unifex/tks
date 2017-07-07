#!/usr/bin/perl
# tks: Time keeping sucks. TKS makes it suck less.
# Author: Martyn Smith
# Copyright (C) 2009 Catalyst IT Ltd (http://www.catalyst.net.nz)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

our $VERSION = '1.0.29';

use strict;
use warnings;

use 5.010;

use lib './lib/';
use Pod::Usage;
use Getopt::Long qw(GetOptions);
use TKS::Timesheet;
use TKS::Backend;
use TKS::Config;
use TKS::Date;
use Term::ANSIColor;

my(%opt);

if(!GetOptions(\%opt, 'help|?', 'version', 'extra', 'section|s=s', 'list|l=s', 'edit|e=s', 'commit|c', 'no-color', 'user|u=s', 'filter|f=s', 'force', 'template|t=s', 'time=i', 'request=i', 'comment=s', 'weekend', 'quiet|q', 'dateformat|d=s', 'query=s', 'maxquery=i')) {
    pod2usage(-exitval => 1,  -verbose => 0);
}

pod2usage(-exitstatus => 0, -verbose => 1) if $opt{help};
if ( $opt{version} ) {
    print "tks version $VERSION\n";
    exit 0;
}
elsif ($opt{dateformat} && $opt{dateformat} !~ m/^(YMD|DMY|MDY|DMonY)$/)
{
    print "Invalid date format selected.\nValid formats are YMD, DMY, MDY and DMonY\n";
    exit 0;
}
elsif ($opt{template} && (($opt{request} && !$opt{time}) || ($opt{time} && !$opt{request})) ) {
    print "For template mode, request and time must both be specified together.\n\n";
    print "tks.pl --time=8 --request=2755808 -t 2017-08-01..2017-08-31\n";
    exit 0;
}


$opt{filename} = shift;

$opt{section} ||= 'default';
$opt{filter} ||= config($opt{section}, 'defaultfilter');
$opt{extra} ||= config($opt{section}, 'extra');
$opt{query} ||= config($opt{section}, 'query');
$opt{maxquery} ||= config($opt{section}, 'maxquery');
delete $opt{filter} if $opt{filter} and $opt{filter} eq 'all';

# quiet mode is only supported when using commit mode (for use from cron)
delete $opt{quiet} if not $opt{commit};

if ( length(join('', map { $opt{$_} ? 'x' : '' } qw(commit list edit template))) > 1) {
    pod2usage(-exitval => 1, -message => "Options commit, list, template, and edit are mutually exclusive\n", -verbose => 0);
}

my $filename = $opt{filename} || config($opt{section}, 'defaultfile');
$filename =~ s( \A ~ / )("$ENV{HOME}/")xmse if defined $filename;

my $backend = TKS::Backend->new($opt{section});

if ( config($opt{section}, 'case-insensitive') ) {
    $TKS::Timesheet::CASE_INSENSITIVE_REQUEST_MAP = 1;
}

my $color_on = ( -t STDOUT and not $opt{'no-color'} );
if ( $opt{template} ) {
    my $timesheet = TKS::Timesheet->new();
    my $request = $opt{request} || '-';
    my $time    = $opt{time} || 0;
    my $comment = $opt{'comment'} || '';
    if ($request eq '-' && $time == 0) {
        $comment = '';
    }
    my $weekend = $opt{'weekend'};
    my @dates = TKS::Date->new($opt{template})->dates;
    unless ($weekend) {
        @dates = TKS::Date->filter(\@dates, {'days',  [1,2,3,4,5]});
    }
    map {
        $timesheet->addentry(TKS::Entry->new(
            date => $_,
            time => $time,
            request => $request,
            comment => $comment,
        ));
    } @dates;
    ts_print($timesheet);
}
elsif ( $opt{list} ) {
    if ( $opt{filename} ) {
        pod2usage(-verbose => 0, -exitval => 1, -message => "using --list with a filename is not supported");
    }
    my $timesheet = $backend->get_timesheet(TKS::Date->new($opt{list}), $opt{user}, $opt{dateformat});
    ts_print($timesheet);
}
elsif ( $opt{edit} ) {
    if ( $opt{filename} ) {
        pod2usage(-verbose => 0, -exitval => 1, -message => "using --list with a filename is not supported");
    }
    my $timesheet = $backend->get_timesheet(TKS::Date->new($opt{edit}));

    map {
        $timesheet->addmentioneddate($_);
    } TKS::Date->new($opt{edit})->dates;

    my $prelude = '';
    if ( $opt{query} ) {
        my $maxrows = $opt{maxquery} || 15;
        $prelude = $backend->saved_search( $opt{query}, $maxrows );
    }

    my $new_timesheet = $timesheet->edit($prelude);

    eval {
        if ( $new_timesheet ) {
            my $diff = $timesheet->diff($new_timesheet);
            $backend->add_timesheet($diff, 1);
            ts_print($new_timesheet);
        }
        else {
            print "Timesheet wasn't saved, no modifications made\n";
        }
    };
    if ($@) {
        error_and_die($@);
    }
}
else {
    die "No file specified" unless $filename;
    die "File $filename not readable" unless -r $filename;
    my $timesheet = TKS::Timesheet->from_file($filename, $opt{force});
    my $filter_warning;

    if ( $opt{filter} ) {
        $filter_warning = $timesheet->time;
        $timesheet = $timesheet->filter_date($opt{filter});
        $filter_warning -= $timesheet->time;
    }

    $timesheet->backend($backend);
    !$opt{quiet} && ts_print($timesheet);
    if ( $opt{commit} ) {
        my $existing = $backend->get_timesheet($timesheet->dates);
        my $diff = $existing->diff($timesheet);
        if ( $diff->entries ) {
            eval {
                if ( $opt{quiet} ) {
                    $backend->add_timesheet($diff, 0);
                }
                else {
                    print STDERR "Committing ...\n";
                    $backend->add_timesheet($diff, 1);
                }
            };
            error_and_die($@) if $@;
        }
        else {
            !$opt{quiet} && print STDERR "No changes, nothing to commit\n";
        }
    }
    if ( $filter_warning ) {
        printf
            "\n%swarning:%s %0.2f hours in your file %s%s%s fell outside the datespec %s%s%s and were not %s\n\n",
            $color_on ? color('bold red') : '',
            $color_on ? color('reset') : '',
            $filter_warning,
            $color_on ? color('bold blue') : '',
            $filename,
            $color_on ? color('reset') : '',
            $color_on ? color('bold blue') : '',
            $opt{filter},
            $color_on ? color('reset') : '',
            $opt{commit} ? 'committed' : 'displayed',
        ;
    }
}

sub ts_print {
    my ($timesheet) = @_;

    if ( -t STDOUT and not $opt{'no-color'} ) {
        print $timesheet->as_color_string($opt{extra} ? $backend : undef);
    }
    else {
        print $timesheet->as_string($opt{extra} ? $backend : undef);
    }
}

sub error_and_die {
    # Uh oh
    print STDERR color 'bold red';
    print STDERR shift . "\n";
    print STDERR color 'reset';
    die "\n";
}

exit 0;

__END__

=head1 NAME

tks - time keeping sucks, TKS makes it suck less

=head1 SYNOPSIS

B<tks> [I<options>] [B<-s> I<section>] [I<file>]

=head1 DESCRIPTION

B<tks> is a utility to make it easier to enter timesheets into
the WRMS instance used inside Catalyst IT.
See L<http://wiki.wgtn.cat-it.co.nz/wiki/Timesheeting> for a description
of timesheeting within the company.

=head1 OPTIONS

=over 4

=item B<-s> I<section>

Use the configuration for the named section in your configuration file.

=item B<--no-color>

Don't output with syntax-highlighting 
(default: use colour if stdout is a tty).

=item B<--help>

Write a summary of command line use.

=item B<--version>

Write the version of the program.

=item B<--extra>

Display extra information as comments after timesheets (if your backend
supports it)

=item B<--quiet>

Do not display any progress or timesheet messages when committing
timesheet (for using TKS from cron).

=item B<--dateformat> I<dateformat>

When the --user option is specified, use the specified date format for
parsing dates returned from the WRMS timesheet report.  This depends on
the selected timeformat for your user account in WRMS.  Valid values are

 YMD (dates in the form YYYY-MM-DD) [default if not specified]
 DMY (dates in the form DD/MM/YYYY)
 MDY (dates in the form MM/DD/YYYY)
 DMonY (dates in the form DD Mon YYYY)

This can also be specified in the configuration file on a per-instance
basis using the key 'dateformat'.

If set, the command-line setting will override the configuration file.

=back

The following options require a filename:

=over 4

=item B<-c>

Write data to the backend (by default just prints what _would_ happen).

=item B<-f>, B<--filter>=I<datespec>

Ignores all entries in the provided file
that fall outside the given I<datespec> (a
warning will be printed if there are
entries that fall outside this range).

=item B<--force>

Turn recoverable errors into warnings when parsing file

=back

The following options do not want a filename:

=over 4

=item B<-l>, B<--list>=I<datespec>

Lists timesheet entries for I<datespec> (output is a valid TKS file).

=item B<-e>, B<--edit>=I<datespec>

Open your C<$EDITOR> with the entries for I<datespec>, 
and after you've edited them, commit them to the system.

=item B<-q>, B<--query>=I<savedquery>

Only works with -e above. Shows a named 'saved query' from WRMS
directly in your timesheet to quickly lookup WR numbers. You can
specify this inside your .tksrc file like so:

 [default]
 query = Allocated
 maxquery = 20

=item B<--maxquery>=I<maxquery>

Limits the number of items shown in a saved query. Defaults to 15

=item B<-t>, B<--template>=I<datespec>

Prints an "empty" timesheet to the standard output
(i.e., just a list of dates in the correct format matching the supplied
I<datespec>).

=item B<--request>=I<number>

=item B<--time>=I<hours>

=item B<--comment>=I<text>

=item B<--weekend>

These options modify the B<--template> option to populate each day with
the provided details. Requires at least B<--request> and B<--time> to be
specified.

B<--request> provides the request number to be used for all entries.

B<--time> provides the number of hours to be recorded for all entries.

B<--comment> is optional and, if provided, will be used as the timesheet
description for time entry.

B<--weekend> if set, will include lines for Saturday and Sunday in the
template. Default is to only include weekdays.

B<NOTE:> tks does not automatically handle public holidays. You will need
to edit the template to remove these if they occur in the template date
range.

=back

I<datespec> can be many things: 
a date (YYYY-MM-DD), 
a list of dates
and/or 
a mnemonic like 'yesterday'. 
Consult the manpage for more information.
(FIXME: This is the manpage, it needs more information added.)

=item B<--request>=I<hours>

=item B<--time>=I<hours>

=item B<--comment>=I<hours>

=item B<--weekend>

These options modify the B<--template> option to populate each day with
the provided details. Requires at least B<--request> and B<--time> to be
specified.

B<--comment> is optional and, if provided, will be used as the timesheet
description for time entry.

B<--weekend> if set, will include lines for Saturday and Sunday in the
template. Default is to only include weekdays.

B<NOTE:> tks does not automatically handle public holidays. You will need
to edit the template to remove these if they occur in the template date
range.

=head2 Datespecs

Some command line arguments take a 'datespec' as their value. Datespecs
represent a list of one or more dates. Some examples follow.

=over 4

=item B<2009/05/25>

An exact date.

=item B<yesterday>

Whatever date yesterday was.

=item B<2009-05-25..2009-06-03,2009-08-01>

All days from the 25th of May to the 3rd of June inclusive, 
and the 1st of August.

=item B<lastmonth..lastweek,today>

From the first day of last month until the last day of 
last week, and today.

=back

The examples should give you a feel for the allowed syntax, 
the following is a more thorough description.

A datespec itself is a list of one or more I<dateparts>, 
separated by commas. 
A datepart can represent just one date, or a list of dates. 
A datepart is either one I<datetoken>, 
or two datetokens separated by C<..>.

Datetokens are specified either in a standard date format, 
or are mnemonics representing dates. 
The mnemonic forms can be modified with C<^> notation to
retrieve previous dates or ranges of dates as appropriate. 
Mnemonics are case insensitive.

As an example, for the datespec:

    2009-05-25..2009-06-03,2009-08-01,today^

There are three dateparts: 
the date range at the start, 
the first of August in the middle,
and the mnemonic at the end.

=over 4

=item *

The first datepart is a range, 
from the first date to the second, inclusive.

=item *

The second datepart is exactly that date.

=item *

The third datepart represents 'yesterday' 
(the mnemonic C<yesterday> works too).

=back

=head1 EDITING TIMESHEETS WITHOUT A TKS FILE

You can do this with C<tks -e>. 
If you accidentally filed a bunch of time for last year, 
or Saturday when you meant Monday, simply run this command, 
change the date and save/quit. 
The time will be moved to the new day.

Naturally, you can alter descriptions/add timesheets etc. in this 
manner also.

=head1 GETTING STARTED

Reading this manpage and simply running tks is a great start. 
You may also be interested in the L<tksrc(5)> manpage.

=head1 EXAMPLE

Parse and output time recorded in this file:

    tks mytime.tks

Commit the time found in this file to the default backend:

    tks -c mytime.tks

Edit the time recorded in system 'foo' on 2009/05/25:

    tks -s foo -e 2009-05-25

Output all time recorded in the default system from last week and today:

    tks -l lastweek,today

Create a template file for a month of annual leave next month:

    tks -t nextmonth --request=12345 --time=8 --comment='Annual leave'

=head1 BUGS

Please report bugs to bugzilla:
L<http://bugzilla.catalyst.net.nz/enter_bug.cgi?product=TKS>

You can see a list of bugs here:
L<http://bugzilla.catalyst.net.nz/buglist.cgi?query_format=specific&order=relevance+desc&bug_status=__open__&product=TKS&content=>

For those people using TKS not at Catalyst IT (greetz to Liip!) - 
please report bugs to whomever introduced TKS to you. 
They'll get back to us eventually.

=head1 AUTHOR

B<tks> is written by Martyn Smith and Nigel McNie. 
Martyn wrote almost all the code for this version, 
while Nigel criticised it constantly 
(he also helped by writing this documentation, 
which might make him redeemable).

=head1 SEE ALSO

L<tksrc(5)>, 
L<http://wiki.wgtn.cat-it.co.nz/wiki/TKS>

=cut


