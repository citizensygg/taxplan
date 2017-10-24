#!/usr/bin/env perl

use strict;
use 5.14.1;

use Data::Dumper;
use FileHandle;
use Getopt::Long;

use File::Path;
use File::Path;
#use File::Copy;

use YAML;
use JSON;


###########################################################################
###########################################################################

our (
     %opts,				#hold command line parameters
     $VERSION,			#collected from CVS Revision
    );

$VERSION	 = 0.4; #sprintf ("%d.%03d", q$Revision$ =~ /(\d+)/g);

my %options_wanted = (
    flags               => [ qw (help|h debug verbose raw
                                ) ],
    flags_negatives     => [ qw () ],
    strings             => [ qw ( mode|m before after maxincome|x) ],
    strings_multiples   => [ qw () ],
    integers            => [ qw () ],
    integers_multiples  => [ qw () ],
);

GetOptions (\%opts,
            (map {  $_     } @{$options_wanted{flags}}),
            (map { "$_!"   } @{$options_wanted{flags_negatives}}),
            (map { "$_=s"  } @{$options_wanted{strings}}),
            (map { "$_=s@" } @{$options_wanted{strings_multiples}}),
            (map { "$_=i"  } @{$options_wanted{integers}}),
            (map { "$_=i@" } @{$options_wanted{integers_multiples}}),
           );

foreach my $opts_type (qw (strings_multiples integers_multiples)) {
    foreach my $opts_field (@{$options_wanted{$opts_type}}) {
        $opts{$opts_field} = [ split (',', join (',', @{$opts{$opts_field}})) ];
    }
}


###########################################################################

our %rate_details;
my @slices = (
			  ( map { $_ *     5000 } (  0 ..  20) ),
			  ( map { $_ *    10000 } ( 11 ..  30) ),
			  ( map { $_ *    50000 } (  6 ..  20) ),
			  ( map { $_ *   100000 } ( 11 ..  30) ),
			  ( map { $_ *  1000000 } (  4 ..  20) ),
			  ( map { $_ * 10000000 } (  3 ..  20) ),
			 );

our $rawjsondir = '../data/rawplans';
our $plansdir   = '../data/details';


###########################################################################
###########################################################################

sub _error {
    say "ERROR: $_[0]\nUse --help for help or --man for manual." and exit(1);
}

###########################################################################

sub _say {
    return unless $opts{verbose};
    say $_[0];
}

###########################################################################

sub _debug_messages {
    return unless $opts{debug};
    say for @_;
}

###########################################################################

sub slurp_file {
    my $filename = shift;
    local $/ = '';
    my $content;
    my $fh = FileHandle->new($filename, "r");
    if (defined $fh) {
        $content = <$fh>;
        undef $fh;       # automatically closes the file
    }
    else {
         _error ("There was a problem reading from '$filename'");
    }
    return ($content);
}

###########################################################################

sub slurp_json
{
    my ($filename, $json) = @_;
    return ($json->decode (slurp_file ($filename)));
}

###########################################################################

sub dump_json
{
    my ($filename, $json, $data) = @_;

    my $fh = FileHandle->new($filename, "w");
    _error ("There was a problem reading from '$filename'") unless (defined $fh);

    print $fh $json->encode ($data);

    undef $fh;       # automatically closes the file
}

###########################################################################
###########################################################################

sub process_raw_to_usable
{
    _say 'entering process_raw_to_usable';
    opendir (DIR, $rawjsondir) or die "could not open $rawjsondir, $!";
    my @files = grep { /\.json/ } readdir DIR;
    closedir DIR;

    mkpath ($plansdir, 1, 0755);
    my $json = JSON->new->pretty ();

    foreach my $planfile (@files) {
        _say ("   now on $planfile");
        my $data = slurp_json ("$rawjsondir/$planfile", $json);
        if ($data->{plan_type} eq 'stepped') {
            process_raw_to_usable_stepped ($data);
        }
        elsif ($data->{plan_type} eq 'slanted') {
            process_raw_to_usable_slanted ($data);
        }
        dump_json ("$plansdir/$planfile", $json, $data);
    }
}

###########################################################################
###########################################################################

sub process_raw_to_usable_stepped
{
    my $data = shift;

    my @rates_in = @{$data->{raw_rates}};

    #do start of first step and declarations to get setup
    my $top = shift (@rates_in);
    my ($low, $rate) = @{$top};
    my $running_total = 0;
    my %inflection_points;
    $inflection_points{$low}++;
    my @layers;

    #loop through steps
    foreach my $row (@rates_in) {
        my ($high, $nextrate) = @{$row};

        my $margin = $high - $low;
        my $base = $margin * $rate / 100;
        $inflection_points{$high}++;

        push (@layers,
              { low             => $low,
                high            => $high,
                margin          => $margin,
                running_total   => $running_total,
                rate            => $rate,
              }
        );

        $running_total += $base;
        $low            = $high;
        $rate           = $nextrate;
    }

    #set final step to infinity
    push (@layers,
          { low             => $low,
            high            => 'top',
            margin          => '-',
            running_total   => $running_total,
            rate            => $rate,
          }
    );

    #save answers
    $data->{calculatable} = [ reverse @layers ];
    $data->{inflections} = [ sort { $a <=> $b } keys %inflection_points ];
}

###########################################################################
###########################################################################

#take low X & Y and high X & Y to calculate slope
sub calculate_slope
{
	my ($lowX, $lowY, $highX, $highY) = @_;
    return ( ($highY - $lowY) / ($highX - $lowX) );
}

#take high X & Y with slope, return low Y (low X is 0 by definition)
sub calculate_zero_rate
{
	my ($highX, $highY, $slope) = @_;
	return ( $highY - ($highX * $slope ) );
}

sub calculate_max_rate
{
	my ($X, $slope, $base) = @_;
	return ( ($X * $slope) + $base );
}

sub calculate_max_point
{
	my ($lowY, $highY, $slope) = @_;
	return ( ($highY - $lowY) / $slope);
}

sub calculate_fullslant
{
	my ($lowY, $highX, $slope) = @_;
	my $rate = ($highX * $slope) + $lowY;
	return ( $highX * $rate / 100 );
}

# the standard points plus any inflection points from selected plans
sub combine_inflection_points
{
    my (@selected_plans) = @_;

    my %points = ( map { $_ => 1 } @slices );
    foreach my $plan ( @selected_plans ) {
        foreach ( @{$plan->{inflections}} ) {
            $points{$_} += 1;
        }
    }

    return ( sort { $a <=> $b } keys %points );
}

###########################################################################

sub process_raw_to_usable_slanted
{
    my $data = shift;

    my %details = ( %{$data->{raw_rates}} );
    my %inflection_points = map { $details{$_} => 1 } (qw (lowpoint highpoint));

    $details{marginal_slope}    = calculate_slope ($details{lowpoint},  $details{lowrate},
                                                    $details{highpoint}, $details{highrate});
    $details{real_slope}        = $details{marginal_slope} / 2;
    $details{fullslant}         = calculate_fullslant ($details{lowrate}, $details{highpoint}, $details{real_slope});

    _say ("slant calculations are" . Dumper (\%details));
    $data->{calculatable}   = \%details;
    $data->{inflections}    = [ sort { $a <=> $b } keys %inflection_points ];
}

###########################################################################
###########################################################################

sub amount_due
{
	my ($plan, $income) = @_;

	if ($plan->{plan_type} eq 'stepped') {
		return stepped_plan ($plan, $income);
	}
    elsif ($plan->{plan_type} eq 'slanted') {
		return slanted_plan ($plan, $income);
	}
}

###########################################################################

sub stepped_plan
{
	my ($plan, $income) = @_;

    my $layers = $plan->{calculatable};

	foreach my $row (@{$layers}) {
		if ($income > $row->{low}) {
			my $tax = ($row->{rate} / 100 * ($income - $row->{low})) + $row->{running_total};
			my $effective_rate = $tax / $income * 100;
			return ( $tax, $effective_rate, $row->{rate});
		}
	}
	return (0, $layers->[-1]{rate}, $layers->[-1]{rate});
}

###########################################################################

sub slanted_plan
{
	my ($plan, $income) = @_;

    my ($tax, $marginal_rate);
    my $details = $plan->{calculatable};

    if ($income > $details->{highpoint}) {
		$tax = ($details->{highrate} * ($income - $details->{highpoint}) / 100) + $details->{fullslant};
		$marginal_rate = $details->{highrate};
	}
    else {
		$tax = ( $income * ($income * $details->{real_slope}     + $details->{lowrate} ) / 100 );
		$marginal_rate =   ($income * $details->{marginal_slope} + $details->{lowrate} );
	}
	my $effective_rate = ($income > 0) ? $tax / $income * 100 : $details->{lowrate};
	return ( $tax, $effective_rate, $marginal_rate);
}

###########################################################################
###########################################################################

sub display_plan
{
	my $planname = shift;

    _error ("$planname.json not available") unless (-s "$plansdir/$planname.json");
    my $json = JSON->new->pretty ();
    my $plan = slurp_json ("$plansdir/$planname.json", $json);

	if ($plan->{plan_type} eq 'stepped') {
		print "         low        high        margin        total  rate\n",
			  "------------ ------------ ------------ ------------ -----\n";
		foreach my $row (@{$plan->{calculatable}}) {
			printf  ("%12d %12.2f %12.2f %12.2f %5.1f\n",
                     ( map { $row->{$_} } qw (low high margin running_total rate) ));
		}
	}
	else {
		print Dumper ($plan->{calculatable});
	}
	print "\n\n";
}

################################################ subroutine header begin ##
# This message should support the options given in the GetOptions call later.
# For more information on how to configure options go to the documentation for
# Getopt::Long at http://search.cpan.org/author/JHI/perl-5.8.0/lib/Getopt/Long.pm
################################################## subroutine header end ##

sub Usage
{

my $message = <<ENDOFUSAGE;
$0 [-h]

Currently supported flags
  -h -help      Display this help message
  -v -verbose	Show more information while it runs
  -d -debug     Used to see the commands without actually running them
  -r -raw       Rebuild plan details from raw yaml (only when adding plan)


Currently supported parameters
  -m -mode      What task do we what to do, pick from:
                  build         Compare all the plan pairs, build html
                  single        Quick print to STDOUT of the selected -before
  -b -before	Plan to work from
  -a -after     Plan to compare against it
  -x -maxincome	Maximum income for the speadsheet


$0 version $VERSION
ENDOFUSAGE

    return (join ("\n\n", @_, $message));
}

###########################################################################
###########################################################################

# Exectution of the Program really begins here

###########################################################################
###########################################################################

die Usage if (exists $opts{help});
 
if (exists $opts{raw}) {
    process_raw_to_usable ();
    exit (0); #may want to remove this when things are working
}

if ($opts{mode} eq 'build') {
}
elsif ($opts{mode} eq 'single') {
    display_plan ($opts{before});
}
else {
	die Usage "Need to pick a mode to do something";
}

###########################################################################
###########################################################################
###########################################################################

__END__

