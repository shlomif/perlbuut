package Bot::BB3::Plugin::Factoids;

use v5.30;
use experimental 'signatures';
use feature 'postderef', 'fc';

use DBI;
use IRC::Utils qw/lc_irc strip_color strip_formatting/;
use Text::Metaphone;
use strict;
use Encode qw/decode/;

use Data::Dumper;
use List::Util qw/min max/;

open(my $fh, "<", "etc/factoid_db_keys") or die $!;
my ($dbname, $dbuser, $dbpass) = <$fh>;
close($fh);

chomp $dbname;
chomp $dbuser;
chomp $dbpass;

#############################
# BIG WARNING ABOUT THE DATABASE IN HERE.
#############################
#
# Despite the name 'original_subject' and 'subject' are logically reversed, e.g. 'original_subject' contains the cleaned up and filtered subject rather than the other way around.
# This should be kept in mind when working on any and all of the code below
#   --simcop2387 (previously also discovered by buu, but not documented or fixed).
#
# This might be fixed later but for now its easier to just "document" it. (boy doesn't this feel enterprisy!)
#
#############################

my $COPULA    = join '|', qw/is are was isn't were being am/, "to be", "will be", "has been", "have been", "shall be", "can has", "wus liek", "iz liek", "used to be";
my $COPULA_RE = qr/\b(?:$COPULA)\b/i;

#this is a hash that gives all the commands their names and functions, added to avoid some symbol table funkery that happened originally.
my %commandhash = (

    #	""          => \&get_fact, #don't ever add the default like this, it'll cause issues! i plan on changing that!
    "forget"     => \&get_fact_forget,
    "learn"      => \&get_fact_learn,
    "relearn"    => \&get_fact_learn,
    "literal"    => \&get_fact_literal,
    "revert"     => \&get_fact_revert,
    "revisions"  => \&get_fact_revisions,
    "search"     => \&get_fact_search,
    "protect"    => \&get_fact_protect,
    "unprotect"  => \&get_fact_unprotect,
    "substitute" => \&get_fact_substitute,
);

my $commands_re = join '|', keys %commandhash;
$commands_re = qr/$commands_re/;

sub new($class) {
    my $self = bless {}, $class;
    $self->{name} = 'factoids';    # Shouldn't matter since we aren't a command
    $self->{opts} = {
        command => 1,
        handler => 1,
    };
    $self->{aliases} = [qw/fact call nfacts/];

    return $self;
}

sub dbh($self) {
    if ($self->{dbh} and $self->{dbh}->ping) {
        return $self->{dbh};
    }

    my $dbh = $self->{dbh} =
      DBI->connect("dbi:Pg:dbname=$dbname", $dbuser, $dbpass, { RaiseError => 1, PrintError => 0 });

    #    DBD::SQLite::BundledExtensions->load_spellfix($dbh);

    return $dbh;
}

sub get_namespace($self, $said) {
    my ($server, $channel) = $said->@{qw/server channel/};

    $server = s/^.*?([^\.]\.[^\.]+)$/$1/;

    return ($server, $channel);
}

sub get_alias_namespace($self, $said) {
    my $conf = $self->get_conf_for_channel($said);

    my $server    = $conf->{alias_server} // $conf->{server}; 
    my $namespace = $conf->{alias_namespace} // $conf->{namespace}; 

    return ($server, $namespace);
}

sub get_conf_for_channel ($self, $said) {
    my ($server, $namespace) = $self->get_namespace($said);

    my $dbh = $self->{dbh};

    my $result = $dbh->selectrow_hashref(qq{
      SELECT * FROM factoid_config WHERE server = ? AND namespace = ? LIMIT 1
    }, {}, $server, $name);

    return $conf;
}

# TODO update this to use the new table layout once it's ready
sub postload {
    my ($self, $pm) = @_;

    # 	my $sql = "CREATE TABLE factoid (
    # 		factoid_id INTEGER PRIMARY KEY AUTOINCREMENT,
    # 		original_subject VARCHAR(100),
    # 		subject VARCHAR(100),
    # 		copula VARCHAR(25),
    # 		predicate TEXT,
    # 		author VARCHAR(100),
    # 		modified_time INTEGER,
    # 		metaphone TEXT,
    # 		compose_macro CHAR(1) DEFAULT '0',
    # 		protected BOOLEAN DEFAULT '0'
    # 	);
    #     CREATE INDEX factoid_subject_idx ON factoid(subject);
    #     CREATE INDEX factoid_original_subject_idx ON factoid(original_subject_idx);
    #     "; # Stupid lack of timestamp fields
    #
    # 	$pm->create_table( $self->dbh, "factoid", $sql );
    #
    # 	delete $self->{dbh}; # UGLY HAX GO.
    # Basically we delete the dbh we cached so we don't fork
    # with one active
}

# This whole code is a mess.
# Essentially we need to check if the user's text either matches a
# 'store command' such as "subject is predicate" or we need to check
# if it's a retrieve command such as "foo" or if it's a retrieve sub-
# command such as "forget foo"
# Need to add "what is foo?" support...
sub command ($self, $_said, $pm) {
    my $said = +{ $_said->%* };

    if ($said->{channel} eq '*irc_msg') {
        # Parse body here
        my $body = $said->{body};
        $said->{channel} = "##NULL" if $said->{channel} eq '*irc_msg';
    }
    
    if ($body =~ /^\s*(?<channel>#\S+)\s+(?<fact>.*)$/) {
        $said->{channel} = $+{channel};
        $said->{body} = $+{fact};
    }

    # TODO does this need to support parsing the command out again?

    my ($handled, $fact_out) = $self->sub_command($said, $pm);

    return ($handled, $fact_out);
}

sub sub_command ($self, $said, $pm, $realchannel, $realserver) {
    return unless $said->{body} =~ /\S/;    #Try to prevent "false positives"

    my $call_only = $said->{command_match} eq "call";

    my $subject = $said->{body};

    my $commands_re = join '|', keys %commandhash;
    $commands_re = qr/$commands_re/;

    my $fact_string;                        # used to capture return values

    if (!$call_only && $subject =~ s/^\s*($commands_re)\s+//) {

        #i lost the object oriented calling here, but i don't care too much, BECAUSE this avoids using strings for the calling, i might change that.
        $fact_string =
          $commandhash{$1}->($self, $subject, $said->{name}, $said);
    } elsif (($subject =~ m{\w\s*=~\s*s /.+ /  .* /[gi]*\s*$}ix)
        || ($subject =~ m{\w\s*=~\s*s\|.+\|  .*\|[gi]*\s*$}ix)
        || ($subject =~ m{\w\s*=~\s*s\{.+\}\{.*\}[gi]*\s*$}ix)
        || ($subject =~ m{\w\s*=~\s*s <.+ > <.* >[gi]*\s*$}ix)
        || ($subject =~ m{\w\s*=~\s*s\(.+\)\(.*\)[gi]*\s*$}ix))
    {
        $fact_string = $self->get_fact_substitute($subject, $said->{name}, $said, $realchannel, $realserver);
    } elsif (!$call_only and $subject =~ /\s+$COPULA_RE\s+/) {
        return if $said->{nolearn};
        my @ret = $self->store_factoid($said, $realchannel, $realserver);

        $fact_string = "Failed to store $said->{body}" unless @ret;

        $fact_string = "@ret" if ($ret[0] =~ /^insuff/i);
        $fact_string = "Stored @ret";
    } else {
        $fact_string = $self->get_fact($pm, $said, $subject, $said->{name}, $call_only, $realchannel, $realserver);
    }

    if (defined $fact_string) {
        return ('handled', $fact_string);
    } else {
        return;
    }
}

# Handler code stolen from the old nfacts plugin
sub handle ($self, $said, $pm) {
    my $conf = $self->get_conf_for_channel($pm, $said->{server}, $said->{channel});

    $said->{body} =~ s/^\s*(what|who|where|how|when|why)\s+($COPULA_RE)\s+(?<fact>.*?)\??\s*$/$+{fact}/i;

    my $prefix = $conf->{prefix_command};
    return unless $prefix;

    # TODO make this channel configurable and make it work properly to learn shit with colors later.
    $said->{body} = strip_formatting strip_color $said->{body};

    if (   $said->{body} =~ /^\Q$prefix\E(?<fact>[^@]*?)(?:\s@\s*(?<user>\S*)\s*)?$/
        || $said->{body} =~ /^\Q$prefix\E!@(?<user>\S+)\s+(?<fact>.+)$/)
    {
        my $fact = $+{fact};
        my $user = $+{user};

        my $newsaid = +{ $said->%* };
        $newsaid->{body} = $fact;

        if ($fact =~ /^\s*(?<channel>#\S+)\s+(?<fact>.*)$/) {
            my ($fact, $channel) = @+{qw/fact channel/};
            $newsaid->{body}    = $fact;
            $newsaid->{channel} = $channel;
        }

        $newsaid->{addressed} = 1;
        $newsaid->{nolearn}   = 1;

        my ($s, $r) = $self->command($newsaid, $pm);
        if ($s) {
            $r = "$user: $r" if $user;
            $r = "\0" . $r;
            return ($r, 'handled');
        }
    }

    return;
}

sub _clean_subject($subject) {
    $subject =~ s/^\s+//;
    $subject =~ s/\s+$//;
    $subject =~ s/\s+/ /g;

    #	$subject =~ s/[^\w\s]//g; #comment out to fix punct in factoids
    $subject = lc fc $subject;

    return $subject;
}

# TODO document this better
sub _clean_subject_func ($subject, $variant) {    # for parametrized macros
    my ($key, $arg);

    if ($variant) {
        $subject =~ /\A\s*(\S+(?:\s+\S+)?)(?:\s+(.*))?\z/s or return;

        ($key, $arg) = ($1, $2);

    } else {
        $subject =~ /\A\s*(\S+)(?:\s+(.*))?\z/s or return;

        ($key, $arg) = ($1, $2);
    }

    return $key, $arg;
}

sub store_factoid ($self, $said) {
    my ($self, $said) = @_;

    # alias namespace is the current alias we assign factoids to
    # server and namespace is the server and channel we're looking up for
    my ($aliasserver, $aliasnamespace) = $self->get_alias_namespace($said);
    my ($server,      $namespace)      = $self->get_namespace($said);

    my ($author, $body) = ($said->{name}, $said->{body});

    return unless $body =~ /^(?:no[, ])?\s*(.+?)\s+($COPULA_RE)\s+(.+)$/s;
    my ($subject, $copula, $predicate) = ($1, $2, $3);
    my $compose_macro = 0;

    return "Insufficient permissions for changing protected factoid [$subject]"
      if (!$self->_db_check_perm($subject, $said));

    if    ($subject =~ s/^\s*\@?macro\b\s*//) {$compose_macro = 1;}
    elsif ($subject =~ s/^\s*\@?func\b\s*//)  {$compose_macro = 2;}
    elsif ($predicate =~ s/^\s*also\s+//) {
        my $fact = $self->_db_get_fact(_clean_subject($subject), $author, $server, $namespace);

        $predicate = $fact->{predicate} . " | " . $predicate;
    }

    return
      unless $self->_insert_factoid($author, $subject, $copula, $predicate, $compose_macro, $self->_db_get_protect($subject, $server, $namespace), $aliasserver, $aliasnamespace);

    return ($subject, $copula, $predicate);
}

sub _insert_factoid ($self, $author, $subject, $copula, $predicate, $compose_macro, $protected, $server, $namespace) {
    my = @_;
    my $dbh = $self->dbh;

    warn "Attempting to insert factoid: type $compose_macro";

    my $key;
    if ($compose_macro == 2) {
        ($key, my $arg) = _clean_subject_func($subject, 1);
        warn "*********************** GENERATED [$key] FROM [$subject] and [$arg]\n";

        $arg =~ /\S/
          and return;
    } else {
        $key = _clean_subject($subject);
    }
    return unless $key =~ /\S/;

    $dbh->do(
        "INSERT INTO factoid 
		(original_subject,subject,copula,predicate,author,modified_time,metaphone,compose_macro,protected, namespace, server)
		VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        undef,
        $key,
        $subject,
        $copula,
        $predicate,
        lc_irc($author),
        time,
        Metaphone($key),
        $compose_macro || 0,
        $protected     || 0,
        $namespace,
        $server
    );

    return 1;
}

sub get_fact_protect ($self, $subject, $name, $said) {
    my ($aliasserver, $aliasnamespace) = $self->get_alias_namespace($said);
    my ($server,      $namespace)      = $self->get_namespace($said);

    warn "===TRYING TO PROTECT [$subject] [$name]\n";

    #XXX check permissions here
    return "Insufficient permissions for protecting factoid [$subject]"
      if (!$self->_db_check_perm($subject, $said));

    my $fact = $self->_db_get_fact(_clean_subject($subject), $name, $server, $namespace);

    if (defined($fact->{predicate})) {
        $self->_insert_factoid($name, $subject, $fact->{copula}, $fact->{predicate}, $fact->{compose_macro}, 1, $aliasserver, $aliasnamespace);

        return "Protected [$subject]";
    } else {
        return "Unable to protect nonexisting factoid [$subject]";
    }
}

sub get_fact_unprotect ($self, $subject, $name, $said) {
    my ($aliasserver, $aliasnamespace) = $self->get_alias_namespace($said);
    my ($server,      $namespace)      = $self->get_namespace($said);

    warn "===TRYING TO PROTECT [$subject] [$name]\n";

    #XXX check permissions here
    return "Insufficient permissions for unprotecting factoid [$subject]"
      if (!$self->_db_check_perm($subject, $said));

    my $fact = $self->_db_get_fact(_clean_subject($subject), $name, $server, $namespace);

    if (defined($fact->{predicate})) {
        $self->_insert_factoid($name, $subject, $fact->{copula}, $fact->{predicate}, $fact->{compose_macro}, 0, $aliasserver, $aliasnamespace);

        return "Unprotected [$subject]";
    } else {
        return "Unable to unprotect nonexisting factoid [$subject]";
    }
}

sub get_fact_forget ($self, $subject, $name, $said) {
    my ($aliasserver, $aliasnamespace) = $self->get_alias_namespace($said);
    my ($server,      $namespace)      = $self->get_namespace($said);

    warn "===TRYING TO FORGET [$subject] [$name]\n";

    #XXX check permissions here
    return "Insufficient permissions for forgetting protected factoid [$subject]"
      if (!$self->_db_check_perm($subject, $said));

    $self->_insert_factoid($name, $subject, "is", " ", 0, $self->_db_get_protect($subject, $server, $namespace), $aliasserver, $aliasnamespace);

    return "Forgot $subject";
}

sub _fact_literal_format($r) {

    # TODO make this express the parent namespace if present
    # <server:namespace>
    ($r->{protected} ? "P:" : "") . ("", "macro ", "func ")[$r->{compose_macro}] . "$r->{subject} $r->{copula} $r->{predicate}";
}

sub get_fact_revisions ($self, $subject, $name) {
    my $dbh = $self->dbh;

    my ($server, $namespace) = $self->get_namespace($said);

    # TODO this query needs to be rewritten
    my $revisions = $dbh->selectall_arrayref(
        "SELECT factoid_id, subject, copula, predicate, author, compose_macro, protected 
			FROM factoid
			WHERE original_subject = ?
			ORDER BY modified_time DESC
		",    # newest revision first
        { Slice => {} },
        _clean_subject($subject),
    );

    my $ret_string = join " ", map {"[$_->{factoid_id} by $_->{author}: " . _fact_literal_format($_) . "]";} @$revisions;

    return $ret_string;
}

sub get_fact_literal ($self, $subject, $name) {

    my ($server, $namespace) = $self->get_namespace($said);
    my $fact = $self->_db_get_fact(_clean_subject($subject), $name, $server, $namespace);

    return _fact_literal_format($fact);
}

sub _fact_substitute ($self, $pred, $match, $subst, $flags) {
    if ($flags =~ /g/) {
        my $regex = $flags =~ /i/ ? qr/(?i:$match)/i : qr/$match/;

        while ($pred =~ /$regex/g) {
            my $matchedstring = substr($pred, $-[0], $+[0] - $-[0]);
            my ($matchstart, $matchend) = ($-[0], $+[0]);
            my @caps =
              map {substr($pred, $-[$_], $+[$_] - $-[$_])} 1 .. $#+;
            my $realsubst = $subst;
            $realsubst =~ s/(?<!\\)\$(?:\{(\d+)\}|(\d+))/$caps[$1-1]/eg;
            $realsubst =~ s/\\(?=\$)//g;

            substr $pred, $matchstart, $matchend - $matchstart, $realsubst;
            pos $pred = $matchstart + length($realsubst);    #set the new position, might have an off by one?
        }

        return $pred;
    } else {
        my $regex = $flags =~ /i/ ? qr/(?i:$match)/i : qr/$match/;

        if ($pred =~ /$regex/) {
            my @caps =
              map {substr($pred, $-[$_], $+[$_] - $-[$_])} 1 .. $#+;
            my $realsubst = $subst;
            $realsubst =~ s/(?<!\\)\$(?:\{(\d+)\}|(\d+))/$caps[$1-1]/eg;
            $realsubst =~ s/\\(?=\$)//g;

            $pred =~ s/$regex/$realsubst/;
        }

        return $pred;
    }
}

sub get_fact_substitute ($self, $subject, $name, $said) {

    my ($aliasserver, $aliasnamespace) = $self->get_alias_namespace($said);
    my ($server,      $namespace)      = $self->get_namespace($said);

    if (   ($said->{body} =~ m{^(?:\s*substitute)?\s*(.*?)\s*=~\s*s /([^/]+ )   /([^/]*  )/([gi]*)\s*$}ix)
        || ($said->{body} =~ m{^(?:\s*substitute)?\s*(.*?)\s*=~\s*s\|([^|]+ )  \|([^|]*  )\|([gi]*)\s*$}ix)
        || ($said->{body} =~ m{^(?:\s*substitute)?\s*(.*?)\s*=~\s*s\{([^\}]+)\}\{([^\}]*?)\}([gi]*)\s*$}ix)
        || ($said->{body} =~ m{^(?:\s*substitute)?\s*(.*?)\s*=~\s*s\(([^)]+ )\)\(([^)]*? )\)([gi]*)\s*$}ix)
        || ($said->{body} =~ m{^(?:\s*substitute)?\s*(.*?)\s*=~\s*s <([^>]+ ) > <([^>]*? ) >([gi]*)\s*$}ix))
    {
        my ($subject, $match, $subst, $flags) = ($1, $2, $3, $4);

        # TODO does this need to be done via the ->get_fact() instead now?
        my $fact = $self->_db_get_fact(_clean_subject($subject), $name, $server, $namespace);

        if ($fact && $fact->{predicate} =~ /\S/) {    #we've got a fact to operate on
            if ($match !~ /(?:\(\?\??\{)/) {          #ok, match has checked out to be "safe", this will likely be extended later
                my $pred = $fact->{predicate};
                my $result;

                #moving this to its own function for cleanliness
                $result = $self->_fact_substitute($pred, $match, $subst, $flags);

                #	my( $self, $body, $name, $said ) = @_;

                #	$body =~ s/^\s*learn\s+//;
                #	my( $subject, $predicate ) = split /\s+as\s+/, $body, 2;

                # TODO why is this calling there?
                # let this fail for now
                my $ret = $self->get_fact_learn("learn $subject as $result", $name, $said, $subject, $result);

                return $ret;
            } else {
                return "Can't use dangerous things in a regex, you naughty user";
            }
        } else {
            return "Can't substitute on unknown factoid [$subject]";
        }
    }
}

sub get_fact_revert ($self, $subject, $name, $said) {
    my $dbh = $self->dbh;

    my ($aliasserver, $aliasnamespace) = $self->get_alias_namespace($said);
    my ($server,      $namespace)      = $self->get_namespace($said);

    #XXX check permissions here
    return "Insufficient permissions for reverting protected factoid [$subject]"
      if (!$self->_db_check_perm($subject, $said));

    $subject =~ s/^\s*(\d+)\s*$//
      or return "Failed to match revision format";
    my $rev_id = $1;

    my $fact_rev = $dbh->selectrow_hashref(
        "SELECT subject, copula, predicate, compose_macro
		FROM factoid
		WHERE factoid_id = ?",
        undef,
        $rev_id
    );

    my $protect = $self->_db_get_protect($fact_rev->{subject}, $server, $namespace);

    return "Bad revision id"
      unless $fact_rev and $fact_rev->{subject};    # Make sure it's valid..

    #                        subject, copula, predicate
    $self->_insert_factoid($name, @$fact_rev{qw"subject copula predicate compose_macro"}, $protect, $aliasserver, $aliasnamespace);

    return "Reverted $fact_rev->{subject} to revision $rev_id";
}

sub get_fact_learn ($self, $body, $name, $said, $subject, $predicate) {

    my ($aliasserver, $aliasnamespace) = $self->get_alias_namespace($said);
    my ($server,      $namespace)      = $self->get_namespace($said);

    return if ($said->{nolearn});

    $body =~ s/^\s*learn\s+//;
    ($subject, $predicate) = split /\s+as\s+/, $body, 2
      unless ($subject && $predicate);

    #XXX check permissions here
    return "Insufficient permissions for changing protected factoid [$subject]"
      if (!$self->_db_check_perm($subject, $said));

    #my @ret = $self->store_factoid( $name, $said->{body} );
    $self->_insert_factoid($name, $subject, 'is', $predicate, 0, $self->_db_get_protect($subject), $aliasserver, $aliasnamespace);

    return "Stored $subject as $predicate";
}

sub get_fact_search ($self, $body, $name) {

    # TODO replace this with FTS

    my ($aliasserver, $aliasnamespace) = $self->get_alias_namespace($said);
    my ($server,      $namespace)      = $self->get_namespace($said);

    $body =~ s/^\s*for\s*//;    #remove the for from searches

    # TODO queries need the CTE

    my $results;

    if ($body =~ m|^\s*m?/(.*)/\s*$|) {
        my $search = $1;

        #XXX: need to also search contents of factoids TODO
        $results = $self->dbh->selectall_arrayref(
            "SELECT subject,copula,predicate 
            FROM factoid 
            JOIN (SELECT max(factoid_id) AS factoid_id FROM factoid GROUP BY original_subject) AS subquery ON subquery.factoid_id = factoid.factoid_id 
            WHERE subject regexp ? OR predicate regexp ?",
            { Slice => {} },
            $search, $search,
        );
    } else {

        #XXX: need to also search contents of factoids TODO
        $results = $self->dbh->selectall_arrayref(
            "SELECT subject,copula,predicate 
            FROM factoid 
            JOIN (SELECT max(factoid_id) AS factoid_id FROM factoid GROUP BY original_subject) AS subquery ON subquery.factoid_id = factoid.factoid_id 
            WHERE subject like ? OR predicate like ?",
            { Slice => {} },
            "%$body%", "%$body%",
        );
    }

    if ($results and @$results) {
        my $ret_string;
        for (@$results) {

            #i want a better string here, i'll probably go with just the subject, XXX TODO
            $ret_string .= "[" . _fact_literal_format($_) . "]\n"
              if ($_->{predicate} !~ /^\s*$/);
        }

        return $ret_string;
    } else {
        return "No matches.";
    }

}

sub get_fact ($self, $pm, $said, $subject, $name, $call_only) {
    return $self->basic_get_fact($pm, $said, $subject, $name, $call_only);
}

sub _db_check_perm ($self, $subj, $said) {
    my ($server, $namespace) = $self->get_namespace($said);

    my $isprot = $self->_db_get_protect($subj, $server, $namespace);

    warn "Checking permissions of [$subj] for [$said->{name}]";
    warn Dumper($said);

    #always refuse to change factoids if not in one of my channels
    return 0 if (!$said->{in_my_chan});

    #if its not protected no need to check if they are op or root;
    return 1 if (!$isprot);

    if ($isprot && ($said->{by_root} || $said->{by_chan_op})) {
        return 1;
    }

    #default case, $isprotect true; op or root isn't
    return 0;
}

#get the status of the protection bit
sub _db_get_protect ($self, $subj, $server, $namespace) {

    # TODO switch to new CTE query

    $subj = _clean_subject($subj, 1);

    my $dbh  = $self->dbh;
    my $prot = (
        $dbh->selectrow_array("
                        SELECT protected
                        FROM factoid
                        WHERE original_subject = ?
                        ORDER BY factoid_id DESC LIMIT 1
                ",
            undef,
            $subj,
        )
    )[0];

    return $prot;
}

sub _db_get_fact ($self, $subj, $func, $namespace, $server) {

    # TODO write the recursive CTE for this

    my $dbh  = $self->dbh;
    my $fact = $dbh->selectrow_hashref("
			SELECT factoid_id, subject, copula, predicate, author, modified_time, compose_macro, protected, original_subject
			FROM factoid 
			WHERE original_subject = ?
			ORDER BY factoid_id DESC
		",
        undef,
        $subj,
    );

    if ($func && (!$fact->{compose_macro})) {
        return undef;
    } else {
        return $fact;
    }
}

sub basic_get_fact ($self, $pm, $said, $subject, $name, $call_only) {
    my ($server,      $namespace)      = $self->get_namespace($said);
    
    #  open(my $fh, ">>/tmp/facts");
    my ($fact, $key, $arg);
    $key = _clean_subject($subject);

    if (!$call_only) {
        $fact = $self->_db_get_fact($key, $name, $server, $namespace);
    }

    # Attempt to determine if our subject matches a previously defined
    # 'macro' or 'func' type factoid.
    # I suspect it won't match two word function names now.

    for my $variant (0, 1) {
        if (!$fact) {
            ($key, $arg) = _clean_subject_func($subject, $variant);
            $fact = $self->_db_get_fact($key, $name, 1, $server, $namespace);
        }
    }

    if ($fact->{predicate} =~ /\S/) {
        if ($fact->{compose_macro}) {
            my $plugin = $pm->get_plugin("compose", $said);

            local $said->{macro_arg} = $arg;
            local $said->{body}      = $fact->{predicate};
            local $said->{addressed} = 1;                    # Force addressed to circumvent restrictions? May not be needed!

            open(my $fh, ">/tmp/wutwut");
            print $fh Dumper($said, $plugin, $pm);

            my $ret = $plugin->command($said, $pm);
            use Data::Dumper;
            print $fh Dumper({ key => $key, arg => $arg, fact => $fact, ret => $ret });

            $ret = "\x00$ret" if ($key eq "tell");

            return $ret;
        } else {
            return "$fact->{predicate}";
        }
    } else {
        if ($subject =~ /[\?\.\!]$/)
        #check if some asshole decided to add a ? at the end of the factoid, if so remove it and recurse, this should only be able to recurse N times so it should be fine
        {
            my $newsubject = $subject;
            $newsubject =~ s/[\?\.\!]$//;
            return $self->basic_get_fact($pm, $said, $newsubject, $name, $call_only);
        }

        my $metaphone = Metaphone(_clean_subject($subject, 1));

        my $matches = $self->_metaphone_matches($metaphone, $subject, $server, $namespace);

        push @{ $said->{metaphone_matches} }, @$matches;

        if (($matches and @$matches) && (!$said->{backdressed})) {
            return "No factoid found. Did you mean one of these: " . join " ", map "[$_]", @$matches;
        } else {
            return;
        }
    }
}

sub _metaphone_matches($self, $metaphone, $subject, $server, $namespace) {
    my $dbh = $self->dbh;

        # TODO this should be using the trigram stuff once it's ready
    my $rows = $dbh->selectall_arrayref(
"SELECT f.factoid_id, f.subject, f.predicate, f.metaphone, spellfix1_editdist(f.metaphone, ?) AS score FROM (SELECT max(factoid_id) AS factoid_id FROM factoid GROUP BY original_subject) as subquery JOIN factoid AS f USING (factoid_id) WHERE NOT (f.predicate = ' ' OR f.predicate = '') AND f.predicate IS NOT NULL AND length(f.metaphone) > 1 AND score < 200 ORDER BY score ASC;",
        undef, $metaphone
    );

    use Text::Levenshtein qw/distance/;    # only import it in this scope

    my $threshold = int(max(4, min(10, 4 + length($subject) / 7)));
    my @sorted =
      map  {$_->[0]}
      sort {$a->[1] <=> $b->[1]}
      grep {$_->[1] < $threshold}
      map  {[$_->[1], distance($subject, $_->[1])]}
      grep {$_->[2] =~ /\S/} @$rows;

    return [grep {$_} @sorted[0 .. 9]];
}

no warnings 'void';
"Bot::BB3::Plugin::Factoids";
__DATA__
Learn or retrieve persistent factoids. "foo is bar" to store. "foo" to retrieve. try "forget foo" or "revisions foo" or "literal foo" or "revert $REV_ID" too. "macro foo is [echo bar]" or "func foo is [echo bar [arg]]" for compose macro factoids. The factoids/fact/call keyword is optional except in compose. Search <subject> to search for factoids that match.
