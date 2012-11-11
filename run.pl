#!/user/local/bin/perl -w
##
## Yi-Chao
##
## perl run.pl <rate of 11a> <rate of 11b> <flow 0 pkt size> <flow 1 pkt size> <flow 0 interval> <flow 1 interval> <flow 0 start time> <flow 1 start time> <global optimization> 
##
## e.g.
##    perl run.pl 6000000 2000000 1000 1000 0.001 0.001 0 0 1
########################################################

use strict;

use POSIX;
use Time::HiRes qw(usleep ualarm gettimeofday tv_interval);



#####
## constant
my $DEBUG0 = 0;
my $DEBUG1 = 1;
my $DEBUG2 = 1;

my $MAX_ROUND = 20;


#####
## input parameters
my $rate_a = 6000000; ## 6Mbps
my $rate_b = 11000000; ## 2Mbps

my $flow0_start_time = 0;   ## flow 0 starts to transmit at XX second
my $flow0_size = 1000;      ## flow 0 generates a 1000byte pkt per 0.001 seconds
my $flow0_intv = 0.001;     ## 
my $flow1_start_time = 0;   ## flow 1 starts to transmit at XX second
my $flow1_size = 1000;      ## flow 1 generates a 1000byte pkt per 0.001 seconds
my $flow1_intv = 0.001;     ##

my $global_optimization = 0; 

if($#ARGV != 8) {
    die "wrong number of input parameters\n";
}
($rate_a, $rate_b, $flow0_size, $flow1_size, $flow0_intv, $flow1_intv, $flow0_start_time, $flow1_start_time, $global_optimization) = @ARGV;
my $output_filename = "out.".join(".", ($rate_a, $rate_b, $flow0_size, $flow1_size, $flow0_intv, $flow1_intv, $flow0_start_time, $flow1_start_time, $global_optimization)).".txt";
print "\n\n".join(",", ($rate_a, $rate_b, $flow0_size, $flow1_size, $flow0_intv, $flow1_intv, $flow0_start_time, $flow1_start_time, $global_optimization))."\n" if($DEBUG1);




#####
## global variables
my $qualnet_exec = "../qualnet";
my $app_filename = "SelectLink.app";
my $config_mother_filename = "SelectLink.mother.config";
my $config_filename = "SelectLink.config";
my $stat_filename = "SelectLink.stat";
my $output_dir = "./output";

my %demands = ();    ## $demands{flow}{xx}{ size | interval }
my %load_stage = (); ## $load_stage{flow}{xx}{ stage | lower | upper }{xx}

my $cnt_round = 0;
my %throughput = ();  ## %throughput{round}{xx}{subround}{xx}{flow}{ 0 | 1 }{ throughput_total | throughput_a | throughput_b | load_a | load_b | selected_subround }{xx}



#####
## main starts

#####
## initialization
assign_demands();
init_load_stage();


foreach my $round_i (0 .. $MAX_ROUND-1) {
    print "\n> round $round_i:\n" if($DEBUG1);


    ###########################################################################
    ## first sub-round
    my $subround = 0;

    #####
    ## get load for each interface depends on previous throughput
    if($global_optimization == 0) {
        calculate_load_per_interface($round_i, $subround);
    }
    elsif($global_optimization == 1) {
        calculate_load_globally($round_i, $subround);
    }
    


    #####
    ## interface a
    clean_file($app_filename);
    create_config('a');
    create_app($round_i, $subround, 'a');

    clean_file($stat_filename);
    my $cmd = "$qualnet_exec $config_filename 2> /dev/null";
    `$cmd`;
    get_throughput($round_i, $subround, 'a');

    # exit if($round_i == 6);


    #####
    ## interface b
    clean_file($app_filename);
    create_config('b');
    create_app($round_i, $subround, 'b');

    clean_file($stat_filename);
    $cmd = "$qualnet_exec $config_filename 2> /dev/null";
    `$cmd`;
    get_throughput($round_i, $subround, 'b');
    # exit;


    ###########################################################################
    ## second sub-round
    $subround = 1;

    #####
    ## get load for each interface depends on previous throughput
    if($global_optimization == 0) {
        calculate_load_per_interface($round_i, $subround);
    }
    elsif($global_optimization == 1) {
        calculate_load_globally($round_i, $subround);
    }


    #####
    ## interface a
    clean_file($app_filename);
    create_config('a');
    create_app($round_i, $subround, 'a');

    clean_file($stat_filename);
    $cmd = "$qualnet_exec $config_filename 2> /dev/null";
    `$cmd`;
    get_throughput($round_i, $subround, 'a');

    # exit if($round_i == 6);


    #####
    ## interface b
    clean_file($app_filename);
    create_config('b');
    create_app($round_i, $subround, 'b');

    clean_file($stat_filename);
    $cmd = "$qualnet_exec $config_filename 2> /dev/null";
    `$cmd`;
    get_throughput($round_i, $subround, 'b');
    # exit;


}   # end of all rounds



print "\n\n\n";
print_throughput();
1;






#####
## function

#####
## assign CBR traffic for each flow
sub assign_demands {
    $demands{flow}{0}{size} = $flow0_size; # bytes
    $demands{flow}{0}{interval} = $flow0_intv; # seconds

    $demands{flow}{1}{size} = $flow1_size; # bytes
    $demands{flow}{1}{interval} = $flow1_intv; # seconds
}


#####
## initialization for load balanceing algorithm
sub init_load_stage {

    foreach my $flow_i (sort {$a <=> $b} keys %{$demands{flow}}) {
        $load_stage{flow}{$flow_i}{stage} = 0;
    }

}


#####
## load balancing algorithm
##   stage 0: exponentially increase 11b load
##   stage 1: binary search
##   
##   to prevent all flows change loads at the same time,
##   which remove the randomness that nodes can change load according to other nodes' change,
##   we introduce sub-round in which one of two flows can change flow first
##
##   @input round_i:    the index of round
##   @input subround_i: allow only one node to change load
sub calculate_load_per_interface {
    my ($round_i, $subround_i) = @_;


    ## number of nodes
    my $flow_num = scalar(keys %{$demands{flow}});
    my $selected_flow = int(rand($flow_num));
    print "$flow_num flows, and $selected_flow is selected\n" if($DEBUG1 && $subround_i == 1);


    foreach my $flow_i (sort {$a <=> $b} keys %{$demands{flow}}) {

        ## in the second selection of each round, only selected flow needs to change load
        # next if( $round_i < 2 || 
        #          ($round_i >= 2 && $subround_i == 1 && $selected_flow != $flow_i) );

        my ($new_load_a, $new_load_b);

        ## first round: 0.99, 0.01
        if($round_i == 0) {
            ($new_load_a, $new_load_b) = (0.96, 0.04);

            $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{selected_subround} = 0;
        }
        ## second round: 0.98, 0.02
        elsif($round_i == 1) {
            ($new_load_a, $new_load_b) = (0.92, 0.08);

            $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{selected_subround} = 0;
        }
        ## thereafter
        else {

            my $pre_throughput;
            my $pre_load_a;
            my $pre_load_b;
            my $pre2_throughput;
            my $pre2_load_a;
            my $pre2_load_b;


            if($subround_i == 0) {
                $pre_throughput = $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{throughput_total};
                $pre_load_a     = $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{load_a};
                $pre_load_b     = $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{load_b};

                if($throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{selected_subround} == 0) {
                    $pre2_throughput = $throughput{round}{$round_i-2}{subround}{1}{flow}{$flow_i}{throughput_total};
                    $pre2_load_a     = $throughput{round}{$round_i-2}{subround}{1}{flow}{$flow_i}{load_a};
                    $pre2_load_b     = $throughput{round}{$round_i-2}{subround}{1}{flow}{$flow_i}{load_b};    
                }
                else {
                    $pre2_throughput = $throughput{round}{$round_i-1}{subround}{0}{flow}{$flow_i}{throughput_total};
                    $pre2_load_a     = $throughput{round}{$round_i-1}{subround}{0}{flow}{$flow_i}{load_a};
                    $pre2_load_b     = $throughput{round}{$round_i-1}{subround}{0}{flow}{$flow_i}{load_b};    
                }
                
            }
            elsif($subround_i == 1) {
                ## select new load if selected in sub-round 1
                if($selected_flow == $flow_i) {
                    $pre_throughput = $throughput{round}{$round_i}{subround}{0}{flow}{$flow_i}{throughput_total};
                    $pre_load_a     = $throughput{round}{$round_i}{subround}{0}{flow}{$flow_i}{load_a};
                    $pre_load_b     = $throughput{round}{$round_i}{subround}{0}{flow}{$flow_i}{load_b};
                    $pre2_throughput = $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{throughput_total};
                    $pre2_load_a     = $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{load_a};
                    $pre2_load_b     = $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{load_b};  

                    $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{selected_subround} = 1;
                }
                ## keep the same ratio if not selected in sub-round 1
                else {
                    $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{load_a} = 
                        $throughput{round}{$round_i}{subround}{0}{flow}{$flow_i}{load_a};
                    $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{load_b} =
                        $throughput{round}{$round_i}{subround}{0}{flow}{$flow_i}{load_b};

                    $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{selected_subround} = 0;
                    next;
                }
            }
            else {
                die "wrong sub-round\n";
            }


            #####
            ## stage 0: exponentially increase 11b load
            if($load_stage{flow}{$flow_i}{stage} == 0) {
                ## if throughput improve, move more to 11b
                if($pre_throughput > $pre2_throughput) {
                    $new_load_b = $pre_load_b * 2;
                    $new_load_a = $pre_load_a - $pre_load_b;
                }
                ## if not improve, move to stage 1 and take the average of pre and pre2
                else {
                    $new_load_b = ($pre_load_b + $pre2_load_b) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    ## set to stage 1
                    $load_stage{flow}{$flow_i}{stage} = 1;
                    $load_stage{flow}{$flow_i}{lower} = $pre2_load_b;
                    $load_stage{flow}{$flow_i}{upper} = $pre_load_b;
                }
            }
            ## stage 1: binary search
            elsif($load_stage{flow}{$flow_i}{stage} == 1) {
                ## if throughput improve, move more to 11b
                if($pre_throughput > $pre2_throughput) {
                    $new_load_b = ($pre_load_b + $load_stage{flow}{$flow_i}{upper}) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    $load_stage{flow}{$flow_i}{lower} = $pre_load_b;
                }
                ## if not improve
                else {
                    $new_load_b = ($pre_load_b + $load_stage{flow}{$flow_i}{lower}) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    $load_stage{flow}{$flow_i}{upper} = $pre_load_b;
                }
            }
            else {
                die "wrong stage\n";
            }
            
        }


        ## special case
        if($new_load_a >= 1) {
            $new_load_a = 1;
            $new_load_b = 0;
        }
        if($new_load_b >= 1) {
            $new_load_b = 1;
            $new_load_a = 0;
        }


        $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_a} = $new_load_a;
        $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_b} = $new_load_b;
        
    }    
}



#####
## load balancing algorithm -- global view
##   stage 0: exponentially increase 11b load
##   stage 1: binary search
##
##   to prevent all flows change loads at the same time,
##   which remove the randomness that nodes can change load according to other nodes' change,
##   we introduce sub-round in which one of two flows can change flow first
##
##   @input round_i:    the index of round
##   @input subround_i: allow only one node to change load
sub calculate_load_globally {
    my ($round_i, $subround_i) = @_;


    ## number of nodes
    my $flow_num = scalar(keys %{$demands{flow}});
    my $selected_flow = int(rand($flow_num));
    print "$flow_num flows, and $selected_flow is selected\n" if($DEBUG1 && $subround_i == 1);


    foreach my $flow_i (sort {$a <=> $b} keys %{$demands{flow}}) {

        ## in the second selection of each round, only selected flow needs to change load
        # next if( $round_i < 2 || 
        #          ($round_i >= 2 && $subround_i == 1 && $selected_flow != $flow_i) );

        my ($new_load_a, $new_load_b);

        ## first round: 0.99, 0.01
        if($round_i == 0) {
            ($new_load_a, $new_load_b) = (0.96, 0.04);

            $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{selected_subround} = 0;
        }
        ## second round: 0.98, 0.02
        elsif($round_i == 1) {
            ($new_load_a, $new_load_b) = (0.92, 0.08);

            $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{selected_subround} = 0;
        }
        ## thereafter
        else {

            my $pre_throughput;
            my $pre_load_a;
            my $pre_load_b;
            my $pre2_throughput;
            my $pre2_load_a;
            my $pre2_load_b;


            if($subround_i == 0) {
                $pre_load_a     = $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{load_a};
                $pre_load_b     = $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{load_b};
                $pre_throughput = 0; 
                foreach my $flow_j (sort {$a <=> $b} keys %{$demands{flow}}) {
                    $pre_throughput += $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_j}{throughput_total};
                }


                if($throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{selected_subround} == 0) {
                    $pre2_load_a     = $throughput{round}{$round_i-2}{subround}{1}{flow}{$flow_i}{load_a};
                    $pre2_load_b     = $throughput{round}{$round_i-2}{subround}{1}{flow}{$flow_i}{load_b};
                }
                else {
                    $pre2_load_a     = $throughput{round}{$round_i-1}{subround}{0}{flow}{$flow_i}{load_a};
                    $pre2_load_b     = $throughput{round}{$round_i-1}{subround}{0}{flow}{$flow_i}{load_b};    
                }
                $pre2_throughput = 0;
                foreach my $flow_j (sort {$a <=> $b} keys %{$demands{flow}}) {
                    if($throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_j}{selected_subround} == 0) {
                        $pre2_throughput += $throughput{round}{$round_i-2}{subround}{1}{flow}{$flow_j}{throughput_total};
                    }
                    else {
                        $pre2_throughput += $throughput{round}{$round_i-1}{subround}{0}{flow}{$flow_j}{throughput_total};
                    }
                }
                
            }
            elsif($subround_i == 1) {
                ## select new load if selected in sub-round 1
                if($selected_flow == $flow_i) {
                    $pre_load_a     = $throughput{round}{$round_i}{subround}{0}{flow}{$flow_i}{load_a};
                    $pre_load_b     = $throughput{round}{$round_i}{subround}{0}{flow}{$flow_i}{load_b};
                    
                    $pre2_load_a     = $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{load_a};
                    $pre2_load_b     = $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_i}{load_b};  

                    $pre_throughput = 0; 
                    $pre2_throughput = 0;
                    foreach my $flow_j (sort {$a <=> $b} keys %{$demands{flow}}) {
                        $pre_throughput += $throughput{round}{$round_i}{subround}{0}{flow}{$flow_j}{throughput_total};
                        $pre2_throughput += $throughput{round}{$round_i-1}{subround}{1}{flow}{$flow_j}{throughput_total};
                    }


                    $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{selected_subround} = 1;
                }
                ## keep the same ratio if not selected in sub-round 1
                else {
                    $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{load_a} = 
                        $throughput{round}{$round_i}{subround}{0}{flow}{$flow_i}{load_a};
                    $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{load_b} =
                        $throughput{round}{$round_i}{subround}{0}{flow}{$flow_i}{load_b};

                    $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{selected_subround} = 0;
                    next;
                }
            }
            else {
                die "wrong sub-round\n";
            }


            #####
            ## stage 0: exponentially increase 11b load
            if($load_stage{flow}{$flow_i}{stage} == 0) {
                ## if throughput improve, move more to 11b
                if($pre_throughput > $pre2_throughput) {
                    $new_load_b = $pre_load_b * 2;
                    $new_load_a = $pre_load_a - $pre_load_b;
                }
                ## if not improve, move to stage 1 and take the average of pre and pre2
                else {
                    $new_load_b = ($pre_load_b + $pre2_load_b) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    ## set to stage 1
                    $load_stage{flow}{$flow_i}{stage} = 1;
                    $load_stage{flow}{$flow_i}{lower} = $pre2_load_b;
                    $load_stage{flow}{$flow_i}{upper} = $pre_load_b;
                }
            }
            ## stage 1: binary search
            elsif($load_stage{flow}{$flow_i}{stage} == 1) {
                ## if throughput improve, move more to 11b
                if($pre_throughput > $pre2_throughput) {
                    $new_load_b = ($pre_load_b + $load_stage{flow}{$flow_i}{upper}) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    $load_stage{flow}{$flow_i}{lower} = $pre_load_b;
                }
                ## if not improve
                else {
                    $new_load_b = ($pre_load_b + $load_stage{flow}{$flow_i}{lower}) / 2;
                    $new_load_a = $pre_load_a + $pre_load_b - $new_load_b;

                    $load_stage{flow}{$flow_i}{upper} = $pre_load_b;
                }
            }
            else {
                die "wrong stage\n";
            }
            
        }


        ## special case
        if($new_load_a >= 1) {
            $new_load_a = 1;
            $new_load_b = 0;
        }
        if($new_load_b >= 1) {
            $new_load_b = 1;
            $new_load_a = 0;
        }


        $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_a} = $new_load_a;
        $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_b} = $new_load_b;
        
    }    
}


#####
## modify config file according to 
##   1) 11a or 11b link
##   2) data rate
##   3) frequency -- not done yet
sub create_config {
    my ($interface) = @_;

    if($interface eq 'a') {
        system("sed 's/PHY-MODEL PHY802.11b/PHY-MODEL PHY802.11a/g;s/PHY-RX-MODEL PHY802.11b/PHY-RX-MODEL PHY802.11a/g;s/PHY802.11-DATA-RATE 2000000/PHY802.11-DATA-RATE $rate_a/g;' $config_mother_filename > $config_filename");
    }
    elsif($interface eq 'b') {
        system("sed 's/PHY802.11-DATA-RATE 2000000/PHY802.11-DATA-RATE $rate_b/g;' $config_mother_filename > $config_filename");
    }
    else {
        die "wrong interface\n";
    }
}



#####
## generate app file which specifies the CBR traffic for each flow
sub create_app {
    my ($round_i, $subround_i, $interface) = @_;


    foreach my $flow_i (sort {$a <=> $b} keys %{$demands{flow}}) {
        print " flows $flow_i\n" if($DEBUG0);


        #####
        ## get demands of this flow
        my $demand_size = $demands{flow}{$flow_i}{size};
        my $demand_interval = $demands{flow}{$flow_i}{interval};


        #####
        ## get load for this interface (11a or 11b) calculated by load balancing algorithm
        my $ratio_interface;
        if($interface eq 'a') {
            $ratio_interface = $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_a};
        }
        elsif($interface eq 'b') {
            $ratio_interface = $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_b};
        }
        else {
            die "wrong interface\n";
        }
        ## CBR packet size must be an integer (by Qualnet)
        my $demand_size_interface = ceil($demand_size * $ratio_interface);  
        my $demand_invl_interface = $demand_interval;
        print $demand_size_interface."\n" if($DEBUG0);


        #####
        ## generate app file
        ##   CBR
        ##   e.g. CBR 1 2 0 1000 0.0001S 0S 0S
        if($flow_i == 0) {
            if($demand_size_interface >= 40) {
                system('echo "CBR 1 2 0 '.$demand_size_interface.' '.$demand_invl_interface.'S '.$flow0_start_time.'S 0S" >> '.$app_filename);
            }
            else {
                system("touch $app_filename");
            }
        }
        elsif($flow_i == 1) {
            if($demand_size_interface >= 40) {
                system('echo "CBR 4 3 0 '.$demand_size_interface.' '.$demand_invl_interface.'S '.$flow0_start_time.'S 0S" >> '.$app_filename);
            }
        }
        else {
            die "wrong number of flows\n";
        }
    }
}


#####
## remove old configure or output file
##   backup if in debug mode
sub clean_file {
    my ($filename) = @_;

    system('cat '.$filename.' >> bak.'.$filename) if($DEBUG2);
    system('echo "\n" >> bak.'.$filename) if($DEBUG2);
    system('rm '.$filename);
}


#####
## parse Qualnet output file to get CBR throughput
sub get_throughput {
    my ($round_i, $subround_i, $interface) = @_;


    foreach my $flow_i (sort {$a <=> $b} keys %{$demands{flow}}) {
        print " $subround_i, 11$interface, flows$flow_i, " if($DEBUG1);


        my $file;
        if($flow_i == 0) {
            $file = "cat $stat_filename | grep CBR | grep Throughput | grep 2, |";
        }
        elsif($flow_i == 1) {
            $file = "cat $stat_filename | grep CBR | grep Throughput | grep 3, |";
        }
        else {
            die "wrong number of flows\n";
        }

        my $new_throughput = 0;
        open FH, $file or die $!;
        while(<FH>) {
            print $_ if($DEBUG0);

            if($_ =~ /=\s+(\d+\.\d*)/) {
                $new_throughput = $1;
            }

            print $new_throughput."\n" if($DEBUG0);
            last;
        }
        close FH;


        if($interface eq 'a') {
            $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_a} = $new_throughput;
            $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_total} = $new_throughput;

            printf("load=%3.0f, %2.3fMbps\n", $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_a}*100, $new_throughput/1000000) if($DEBUG1);
            
        }
        elsif($interface eq 'b') {
            $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_b} = $new_throughput;
            $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_total} += $new_throughput;

            # print "   b=$new_throughput, sum=".$throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_total}."\n" if($DEBUG0);
            printf("load=%3.0f, %2.3fMbps, sum=%2.3fMbps\n", 
                $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_b}*100, 
                $new_throughput/1000000, 
                $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_total}/1000000) if($DEBUG1);

        }
        else {
            die "wrong interface\n";
        }
    }
}



#####
## print out %throughput
##   %throughput has entire information of this simulation
##   - %throughput format: 
##     %throughput{round}{xx}{subround}{xx}
##                {flow}{ 0 | 1 }
##                { throughput_total | throughput_a | throughput_b | load_a | load_b }{xx}
##   - print format: 
##     round, [flow1: load_a, load_b, throughput_sum, throughput1, throughput2], [flow2: load_a, load_b, throughput_sum, throughput1, throughput2], ...
sub print_throughput {

    open OUTPUT, "> $output_dir/$output_filename" or die $!;
    
    print OUTPUT "time, subround, [flow1: load_a, load_b, throughput_sum, throughput1, throughput2],\n";
    print OUTPUT "                [flow2: load_a, load_b, throughput_sum, throughput1, throughput2], \n";
    print OUTPUT "      subround, [flow1: load_a, load_b, throughput_sum, throughput1, throughput2],\n";
    print OUTPUT "                [flow2: load_a, load_b, throughput_sum, throughput1, throughput2], \n";
    
    foreach my $round_i (sort {$a <=> $b} keys %{$throughput{round}}) {
        printf("t%02d, ", $round_i);
        printf(OUTPUT "t%02d, ", $round_i);

        foreach my $subround_i (sort {$a <=> $b} keys %{$throughput{round}{$round_i}{subround}}) {
            print  "     " if($subround_i != 0);
            printf("r%d, ", $subround_i);
            print OUTPUT "     " if($subround_i != 0);
            printf(OUTPUT "r%d, ", $subround_i);

            foreach my $flow_i (sort {$a <=> $b} keys %{$throughput{round}{$round_i}{subround}{$subround_i}{flow}}) {
                print  "         " if($flow_i != 0);
                printf("f%d, ", $flow_i);
                print OUTPUT "         " if($flow_i != 0);
                printf(OUTPUT "f%d, ", $flow_i);

                printf("%3.0f, %3.0f, %2.2f, %2.2f, %2.2f", 
                    $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_a}*100, 
                    $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_b}*100,
                    $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_a}/1000000,
                    $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_b}/1000000,
                    $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_total}/1000000);
                printf(OUTPUT "%3.0f, %3.0f, %2.2f, %2.2f, %2.2f", 
                    $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_a}*100, 
                    $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{load_b}*100,
                    $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_a}/1000000,
                    $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_b}/1000000,
                    $throughput{round}{$round_i}{subround}{$subround_i}{flow}{$flow_i}{throughput_total}/1000000);

                if($subround_i == 1 && 
                   $throughput{round}{$round_i}{subround}{1}{flow}{$flow_i}{selected_subround} == 1) {
                    print "  v\n";
                    print OUTPUT "  v\n";
                }
                else {
                    print "\n";
                    print OUTPUT "\n";
                }
            }

            # print "\n";
        }
    }

    close OUTPUT;
}
