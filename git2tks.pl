#!/usr/bin/perl
# git2tks - makes a TKS file using git commit log
# Author: Brendan Heywood <brendan@catalyst-au.net>
# Copyright (C) 2013 Catalyst IT Ltd (http://www.catalyst-au.net)
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

our $VERSION = '1.0.0';

use strict;
use warnings;
use Data::Dumper;
use Date::Format ();
use Date::Parse ();
use Getopt::Long;
use POSIX;

sub usage {
    use File::Basename;
    my $cmd = basename($0);
    print <<EOF;
Converts your git commit logs into TKS format

It will:
  * pull data from current repo
  * pull data from all local branches, each duplicate commit will be present
    but with zero time (tks ignores it but here so you could use it instead)
  * branch names are sanitized and become your .tksrc WR aliases
  * Assumes we start useful work at 9am (emails etc should be a separate WR record)
  * Is generally a starting point, entries should be sanitised before use

> $cmd -d 14    # show 14 days (default to 7)
> $cmd -s 8     # I start at 8am (default 9am)
> $cmd -u jim   # Show someone else's data
> $cmd -p repo  # Use a path instead of the current working dir

See the man page for more details.

EOF
    exit;
}

my $days  = 7; # how far back in time to we look?
my $user  = `whoami`;
my $help = 0;
my @paths = ('.');
my $wr;
my $ignore;
my $starttime = 9; # What hour of the day do you start at?
chomp $user;

GetOptions (
    "d|days=f"   => \$days,
    "s|start=f"  => \$starttime,
    "u|user=s"   => \$user,
    "w|wr=s"     => \$wr,
    "i|ignore"   => \$ignore,
    "h|help"     => \$help,
) or die usage();

if( $help ){
    usage();
    exit;
}

sub findCommits {
    my ($wr, $cwd, $system, $branch, $user, $days) = @_;
    my @commits;
    my $cmd = "git log --since=".$days.".days --author=$user $branch";
    my @res = split '\n', `$cmd`;
    $branch =~ s/\./-/g;

    while ($#res > -1){
        my $commit    = substr(shift @res,7,10);
        my $author    = shift @res;
        if (substr($author,0,5) eq 'Merge'){
            $author    = shift @res;
        }
        my $date      = substr(shift @res,8);
        my $timestamp = Date::Parse::str2time($date);
        my $dud       = shift @res;
        my $msg       = substr(shift @res, 4);
           $dud       = shift @res;
        if (substr($msg,0,6) eq 'Revert'){
           $dud       = shift @res;
           $dud       = shift @res;
        }
        if ($wr){
            $branch = $wr;
        }

        my @stuff = ($timestamp,$date,$msg,$branch,$commit, $system);
        push @commits, \@stuff;
    }
    return @commits;
}

sub findCommitsForRepo {
    my ($wr, $cwd, $system, $user, $days) = @_;
    my @coms;
    my $remote = `git remote -v 2>&1`;

    if ($remote =~ /fatal/){
        # not a git repo
        return;
    }

    # Find a pretty repo name
    $remote =~ s/.*?\w+(.*)\(fetch.*/$1/gs;
    $remote = basename($remote);
    $remote =~ s/\.[^.]+$//;

    my @branches = split '\n', `git branch`;
    foreach my $branch (@branches){
        $branch = substr($branch,2);
        push @coms, findCommits($wr, '.', $remote, $branch, $user, $days);
    }
    return @coms;
}

my @commits;

if($#ARGV ne -1){
    @paths = @ARGV;
}

my $basedir = getcwd();

foreach my $path (@paths){
    if ($path !~ /\//){
        $path = $basedir.'/'.$path;
    }
    if (!-d $path){ next; }
    print "# Looking in $path \n";
    chdir $path;
    push @commits, findCommitsForRepo($wr, '.', 'moodle', $user, $days);
}

my $lastdate='';
my $lasttime = $starttime;
my $daytotal = 0;

@commits = sort {
    $a->[0] <=> $b->[0] # sort by commit time
    or
    $a->[3] cmp $b->[3] # sort by name, eg release-2-1 is before release-2-1
} @commits;

sub ft {
    my ($hours) = @_;
    my $dh = floor($hours);
    my $dm = $hours - $dh;
    return sprintf "%2s:%02d", $dh, $dm * 60;
}

foreach my $commit (@commits){

    my @com = @$commit;
    my $date = Date::Format::time2str("\n%Y-%m-%d # %A \n",$com[0], 'GMT');
    my $time = Date::Format::time2str("%H:%M ",$com[0], 'AEST');

    if ($date ne $lastdate){
        if ($daytotal){
            print "#               ".ft($daytotal)."   total hours\n";
        }
        print "$date";
        $lasttime = $starttime;
        $daytotal = 0;
    }

    $time = substr($time,0,2) + substr($time,3,2)/60 ;
    my $delta = $time - $lasttime;
    if ($delta < 0){
        $delta = 1; # Most things take about an hour
    }
    $daytotal += $delta;
    if ($ignore && $delta == 0){
        # this collapses commits on two branches
        next;
    }
    printf "%-15s%6.2f   %s (%s: %s)\n", $com[3], $delta, $com[2], $com[5], $com[4];

    $lastdate = $date;
    $lasttime = $time;
}
print "#               ".ft($daytotal)."   total hours\n\n";


__END__

=head1 NAME

git2tks - generates a TKS file from your git commit log(s)

=head1 SYNOPSIS

B<git2tks> [B<-h>]

- display brief usage information

B<git2tks> [B<-d> I<days>] [B<-s> I<starttime>] [B<-u> I<user>] [REPO-PATH(s)] 

=head1 DESCRIPTION

B<git2tks> is a utility included with tks that converts your git commit log
into TKS records. To do this it makes some wild assumptions like:

- you have only worked on one thing at a time

- each time records starts from the most recent git commit time (even on another repo)

- if no previous commit that day, assumes 9am (time to read emails etc)

- if you commited something before the start of the day, defaults to 1 hour

- you haven't squashing of commits that would mess up the timestamps

- you never take a break or eat lunch, or do anything except stuff in git

- your git timestamps are correct, ie your box and VM's etc have the right time

Because of these assumptions it is intended that you review and massage the
output before you save it via TKS into WRMS.

=head1 MAPPING BRANCHES TO WR's

In the project which inspired this (Open2Study) each release branch has a
separate WR for each release. git2tks uses a tks sanitised version of the
branch name as the tks WR alias, so you can set these up to map to WR's
however you like using the [requestmap] in your .tksrc file:

https://wiki.wgtn.cat-it.co.nz/wiki/TKS#tksrc

If you just want them all to be against a single WR number or alias you can
use the B<--wr> option to override them.

=head1 SHARED COMMITS

If you have commits which are on multiple branches, only one of these will
show up with the correct time, the rest will have a time record of 0. This
is so it won't get counted twice when importing into TKS. Both records are
left there for convenience so you can swap them over.

It attempts to find the 'earliest' branch as the one that gets the hours by
default. If you use a branch naming convention like semver.org things should
work out. Happily 'master' is before 'release-x-y' so it takes precendence.

If you've got heaps of branches and the extra rows just add clutter, you can
turn them off with the B<--ignore> option.

=head1 OPTIONS

=over 4

=item B<-h|--help>

Show brief usage information for the program and exit.

=back

=over 4

=item B<-d|--days> I<days>

Specify how far back in time to look for commits. Default is 7

=back

=over 4

=item B<-s|--start> I<starttime>

Specify a start time for each day, defaults to 9

=back

=over 4

=item B<-u|--user> I<user>

Show a timesheet for another user, must match what is in git

=back

=over 4

=item B<-w|--wr> I<work-request>

Use one WR number or alias for all entries

=back

=over 4

=item B<-i|--ignore>

Ignore commits which are duplicated across branche's

=back

=over 4

=item B<REPO-PATH(s)>

git2tks works if you are anywhere inside a git repo, or you can pass in
multiple paths to various repos. If you pass multiple repo's it will 
detect swapping work between them over the day.

git2tks /var/www/*

For convenience it tries to find a nice short name for each repo as a suffix
to the git hash so you can tell them apart.

=back

=head1 AUTHOR

Brendan Heywood <brendan@catalyst-au.net>

=head1 SEE ALSO

http://wiki.wgtn.cat-it.co.nz/wiki/TKS

=cut
