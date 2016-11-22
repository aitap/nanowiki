#!/usr/bin/env perl
package App::NanoWiki::admincmd;
use Mojo::Base 'Mojolicious::Command';
has description => 'Administrative commands for NanoWiki';
has usage => <<EOM;
Usage: $0 admincmd <command> [arguments...]

Available commands:

init
	Write default config file, create the database file and tables
upgradedb
	Upgrade the database to match the application schema version.
maintaindb
	Run VACUUM, ANALYZE, on the DB; run 'optimize' on FTS table.

delete <page> [page ...]
	Delete specified pages completely
rename <from> <to>
	Move a page from one path to another. Ordinary paths look like
	"Welcome/subpage/subsubpage".

export <directory>
	Export the wiki as a series of text files containing Textile
	source of the articles to the specified directory.

Warning: the commands in question are potentially destructive and
should be used with caution!
EOM

sub run {
	my ($self, @args) = @_;
	use Mojo::Util qw(encode decode);
	my %commands = (
		init => sub {
			use Data::Dumper; # shock, horrors! writing config using Dumper!
			use autodie; # open, print, close
			my $config = $self->app->config;
			open my $conf_handle, ">:utf8", $self->app->conffile; # still looks ugly?
			print $conf_handle Data::Dumper::->new([$config], ['config'])->Terse(1)->Useqq(1)->Deparse(1)->Dump;
			close $conf_handle;
			my $dbh = $self->app->dbh;
			$dbh->query($_) or die $dbh->error for (
"create table pages (
	title text not null,
	who text not null,
	src text,
	html text,
	time integer not null,
	parent text not null,
	primary key (title, time)
);",
"create index pages_title on pages (title);", # GET /path/to/page
"create index pages_parent on pages (parent);", # list of children
"create table sessions (
	id text primary key not null,
	human bool not null,
	expires integer not null,
	answer text not null
);",
"create index sessions_id_expires on sessions (id, expires);", # look up whether a session is valid
"create index sessions_expires on sessions (expires);", # clean up stale sessions
'create virtual table ftsindex using fts4(content="pages",src,title,tokenize=unicode61)',
"create trigger pages_before_update before update on pages begin
	delete from ftsindex where docid=old.rowid;
end;",
"create trigger pages_before_delete before delete on pages begin
	delete from ftsindex where docid=old.rowid;
end;",
"create trigger pages_after_update after update on pages begin
	insert into ftsindex(docid,src,title) values(new.rowid,new.src,new.title);
end;",
"create trigger pages_before_insert before insert on pages begin
	delete from ftsindex where docid in (select rowid from pages where title=new.title);
end;",
"create trigger pages_after_insert after insert on pages begin
	insert into ftsindex(docid,src,title) values(new.rowid,new.src,new.title);
end;",
"pragma user_version = ".$self->app->schema_version.";"
			);
		},
		delete => sub {
			return unless @_; # delete from pages; -- haha
			say "Deleted "
				.$self->app->dbh->delete('pages', { title => { '=' , [ map { decode utf8 => $_ } @_ ] } })->rows
				." rows";
		},
		rename => sub {
			die "Usage: rename <from> <to>\n" unless @_ == 2;
			my ($from, $to) = map { decode utf8 => $_ } @_;
			(my $parent = $to) =~ s{/[^/]+$}{}; # FIXME: parent regexp copy-paste
			say "Updated "
				.$self->app->dbh->update('pages', { title => $to, parent => $parent }, { title => $from })->rows
				." rows";
		},
		export => sub {
			use autodie; # chdir, open, close, print...
			use File::Path 'make_path';
			die "Usage: export <directory>\n" unless @_ == 1;
			my $dbh = $self->app->dbh; # it dies and takes the sth with it otherwise
			my $result = $dbh->query(
				"select p.title, p.src, p.time from pages p
				inner join (select title, max(time) as latest from pages group by title) gp
				on gp.title == p.title and p.time == gp.latest"
			) or die $dbh->error;
			while (my $row = $result->array) {
				my ($title, $text, $time) = @$row;
				$title = encode utf8 => "$_[0]/$title.txt";
				(my $dirname = $title) =~ s{/[^/]+$}{};
				make_path $dirname;
				open my $write, ">:utf8:crlf", $title;
				print $write "$time # revision ".scalar(localtime $time)." -- please do not touch this line\n";
				print $write $text;
				print "$time $title\n";
			}
		},
		import => sub {
			use autodie; # open, readline...
			use File::Find 'find';
			die "Usage: import <directory>\n" unless @_ == 1 and -d $_[0];
			my ($dir) = @_;
			my $dbh = $self->app->dbh;
			find({wanted => sub {
				my $found = $File::Find::name;
				# we only care about *.txt files
				return unless -f $found and $found =~ /\.txt$/;
				open my $read, "<:utf8:crlf", $found;
				$found =~ s{^\Q$dir\E/}{}; $found =~ s/\.txt$//; $found = decode utf8 => $found;
				my $time = (scalar(<$read>) =~ /^\s*(\d+)/)[0];
				die "Can't read mtime of $File::Find::name; was the first line damaged?\n" unless $time;
				if (($dbh->query("select count(time) from pages where time > (?+0) and title = ?",$time, $found)->flat)[0]) {
					warn "$time $File::Find::name -- not importing because there are newer edits\n";
					return;
				}
				my $src = do { local $/; <$read> };
				if (($dbh->query("select count(time) from pages where time = (?+0) and src = ? and title = ?", $time, $src, $found)->flat)[0]) {
					print "$time $File::Find::name -- unchanged\n";
					return;
				}
				$self->app->insert_page_revision($found,$src,"local import")
					or die "$time $File::Find::name ".$dbh->error;
				print "$time $File::Find::name\n";
			}, no_chdir => 1}, $dir);
		},
		upgradedb => sub {
			my @upgradefrom = (
				[
					# create primary key (title, time) on pages
					# and add NOT NULL constraints to most columns
"create table pages_ (
	title text not null,
	who text not null,
	src text,
	html text,
	time integer not null,
	parent text not null,
	primary key (title, time)
);",
"insert into pages_ select * from pages;",
"drop table pages;",
"alter table pages_ rename to pages;",
"create index pages_title on pages (title);",
"create index pages_parent on pages (parent);",
					# add NOT NULL to the sessions table
					# also, get rid of unused "challenge" column for free, if it ever existed
"create table sessions_ (
	id text primary key not null,
	human bool not null,
	expires integer not null,
	answer text not null
);",
"insert into sessions_ select id, ifnull(human,0), expires, answer from sessions;",
"drop table sessions;",
"alter table sessions_ rename to sessions;",
"create index sessions_id_expires on sessions (id, expires);",
"create index sessions_expires on sessions (expires);",
					# create the FTS table
'create virtual table ftsindex using fts4(content="pages",src,title,tokenize=unicode61)',
"create trigger pages_before_update before update on pages begin
	delete from ftsindex where docid=old.rowid;
end;",
"create trigger pages_before_delete before delete on pages begin
	delete from ftsindex where docid=old.rowid;
end;",
"create trigger pages_after_update after update on pages begin
	insert into ftsindex(docid,src,title) values(new.rowid,new.src,new.title);
end;",
"create trigger pages_before_insert before insert on pages begin
	delete from ftsindex where docid in (select rowid from pages where title=new.title);
end;",
"create trigger pages_after_insert after insert on pages begin
	insert into ftsindex(docid,src,title) values(new.rowid,new.src,new.title);
end;",
"insert into ftsindex(docid,src,title)
	select p.rowid, p.src, p.title from pages p
		inner join (select title, max(time) as latest from pages group by title) gp
		on gp.title == p.title and p.time == gp.latest;", # populate index with latest revisions
					# last, update the schema version
"pragma user_version = 1;"
				],
			);
			my $dbh = $self->app->dbh;
			my $appver = $self->app->schema_version;
			$dbh->query("pragma user_version;")->into(my $dbver);
			if ($dbver > $appver) {
				die "Cannot downgrade database from $dbver to $appver. Please upgrade the application.\n";
			}
			while ($appver > $dbver) {
				print "Upgrading from version $dbver\n";
				$dbh->begin_work;
				unless(eval {
					$dbh->query($_) or die $dbh->error for @{$upgradefrom[$dbver]};
					1;
				}) {
					$dbh->rollback;
					die;
				}
				$dbh->commit;
				$dbh->query("pragma user_version;")->into($dbver);
			}
			print "Application schema version ($appver) matches database version ($dbver)\n";
		},
		dump => sub {
			...;
		},
		maintaindb => sub {
			my $dbh = $self->app->dbh;
			$dbh->query($_) or die $dbh->error for (
				"vacuum;", "insert into ftsindex(ftsindex) values ('optimize');", "analyze;"
			);
		},
	);
	unless (@args and exists $commands{$args[0]}) {
		$self->help; exit(1);
	}
	$commands{$args[0]}->(@args[1..$#args]);
}

package App::NanoWiki;
use Mojolicious::Lite;
use DBIx::Simple;
use Session::Token;
use Text::Textile 'textile';
use Scalar::Util 'looks_like_number';

app->attr(conffile => $ENV{NANOWIKI_CONFIG} // "nanowiki.cnf"); # to use it from ::command
app->attr(schema_version => 1);

my $config = {%{plugin Config => {
	file => app->conffile, default => {
		sqlite_filename => "nanowiki.db",
		session_entropy => 128,
		secrets => [Session::Token::->new(entropy => 2048)->get],
		root_page => "Welcome",
		session_timeout => 60*60*24*7, # sessions expire if not used in one week
		session_cleanup_probability => .05,
	}
}}};
# XXX: make a copy so we don't accidentally put *_captcha to the original
# which might get written to a file by admincmd init
# ugly?

app->secrets(app->config("secrets"));
app->sessions->default_expiration($config->{session_timeout});
$config->{get_captcha} ||= \&get_captcha;
$config->{check_captcha} ||= \&check_captcha;

helper 'dbh' => sub {
	my $dbh = DBIx::Simple::->connect("dbi:SQLite:dbname=".$config->{sqlite_filename},"","",{
		sqlite_unicode => 1,
		AutoCommit => 1,
		RaiseError => 1,
	});
	# ->dbh to get the DBI object
	$dbh->dbh->sqlite_create_function("searchrank", -1, sub {
		use List::Util "sum";
		my ($matchinfo_blob, @weights) = @_;
		# when called with "pcx" arguments (default), matchinfo returns:
		# - number of phrases
		# - number of columns
		# - {
		#   - [+0] num(appears here)
		#   - [+1] sum(appearances): phrase appears in column
		#   - [+2] num(rows): phrase appears in column
		#   } per column, then per phrase
		# = 32-bit unsigned integers in machine byte-order
		my ($nphrases, $ncols, @matchinfo) = unpack "L*", $matchinfo_blob;
		# rank = sum { <appears here> / <appears in column> * weight } per phrase per column
		return sum map {
			my $phrase = $_;
			sum map {
				my $nhits = $matchinfo[3*($phrase*$ncols+$_)];
				$nhits ? ($nhits / $matchinfo[3*($phrase*$ncols+$_)+1] * $weights[$_]) : ()
			} (0 .. $ncols)
		} (0 .. $nphrases-1);
	});
	return $dbh;
};

app->dbh->query("pragma user_version;")->into(my $dbversion);
if (
	(($ARGV[0]//"") ne "admincmd")
	and (
		my $cmp = ($dbversion <=> app->schema_version) # a complicated way to say !=
	)
) {
	if (! -s $config->{sqlite_filename} ) {
		die "Database file $config->{sqlite_filename} is empty. Run '$0 admincmd init' to create the config and initialize the DB.\n";
	}
	die "Database version ($dbversion) doesn't match the application version (".app->schema_version.").\n"
	    .(
			undef, # 0 means equal and shouldn't happen
			"Unfortunately, database downgrades are not supported. Please upgrade the app ($0).\n", # 1 means that DB is newer than app
			"Use '$0 admincmd upgradedb' to upgrade the schema. Backup the database (".$config->{sqlite_filename}.") first.\n", # -1 means that DB is older than app
		)[$cmp];
}


# from Mojolicious::Guides::Tutorial
helper 'whois' => sub {
	my $c     = shift;
	my $agent = $c->req->headers->user_agent || 'empty User-Agent';
	my $ip    = $c->tx->remote_address;
	return "$agent ($ip)";
};

helper 'path_links' => sub { # transform /A/B/C from stash into series of links to /A, /A/B, /A/B/C
	my $c = shift;
	my $path = $c->stash("title");
	# split path into parts to linkify them in the template
	my @pathspec = map { [ $_ ] } split /\//, $path;
	$pathspec[0][1] = "/$pathspec[0][0]";
	$pathspec[$_][1] = "$pathspec[$_-1][1]/$pathspec[$_][0]" for 1..$#pathspec;
	return @pathspec;
};

helper 'title_from_path' => sub { # stash: /A/B/C -> C
	my $c = shift;
	my ($title) = $c->stash("title") =~ m{([^/]+)$};
	return $title;
};

helper children => sub { # all pages which have current as their parent
	my $c = shift;
	my $dbh = $c->dbh;
	return
		map {
			my ($title) = m{([^/]+)$};
			[ $title, $_ ]
		}
		$dbh->query("select distinct(title) from pages where parent = ?", $c->stash("title"))->flat
		;
};

sub get_captcha {
	my @operands = qw(- + / *);
	my $challenge = int rand 20;
	$challenge .= " ".$operands[int rand @operands]." ".(int(rand 20)+1) for 1..2;
	my $answer = eval $challenge; # string eval! shock, horrors!
	my %digits = map {
		my $dig = $_;
		( $dig => [ map { chr ($_ + $dig) } (0x1d7cE, 0x1d7d8, 0x1d7e2, 0x1d7ec, 0x1d7f6, 0xff10, 0x30) ] )
	} (0..9);
	$challenge =~ s/(\d)/$digits{$1}[int rand @{$digits{$1}}]/ge;
	return ($challenge, $answer);
}

sub check_captcha {
	my ($answer, $to_check) = @_;
	$to_check =~ tr/,/./;
	return (looks_like_number($to_check) and abs($to_check - $answer) <= 1e-2);
}

helper check_human => sub { # to be used in edit.htm and post controller
	my $c = shift;
	my $id = $c->session('id');
	my $dbh = $c->dbh();
	if (rand() < $config->{session_cleanup_probability}) {
		# I'm too reluctant to try to implement a cron-like something
		$dbh->query('delete from sessions where expires < (0+?)',time)
			or die $dbh->error;
	}
	if ( $id
		&& $dbh
			->query('select human, expires, answer from sessions where id = ? and expires > (0+?)',$id,time)
			->into(my($human, $expires, $answer))
	) { # session has a somewhat valid id
		if (!$human) { # there is a valid captcha session, but not a human session => must be an answer
			my $to_check = $c->param('captcha');
			if (defined $to_check and $config->{check_captcha}($answer, $to_check)) { # valid answer
				$human = 1;
			} else { # no answer or invalid
				$dbh->delete('sessions',{id=>$id}) or die $dbh->error; # delete the session so it won't be used again
			}
		}
		if ($human) { # passed captcha sometime in the past => touch the session in DB and cookies
			$dbh->update('sessions', { expires => time + $config->{session_timeout}, human => 1 }, { id => $id }) or die $dbh->error;
			$c->session(id => $id); # touch session->id to make it last longer; XXX: is it needed?
			return 1; # confirmed human; free to pass
		}
	} # else there is no valid session in the first place => possible unhuman
	return;
};

helper captcha_field => sub {
	my $c = shift;
	return "" if $c->check_human;
	# at this point: either the session was valid and there is no captcha, or the session does not exist
	# even if there was a session ID, there isn't now => captcha_field can feel free to create a new one
	my $dbh = $c->dbh;
	my $id = Session::Token::->new(entropy => $config->{session_entropy})->get;
	my ($challenge, $answer) = $config->{get_captcha}();
	$dbh->insert(
		'sessions',
		{
			id => $id, expires => time + $config->{session_timeout},
			answer => $answer, human => 0
		}
	) or die $dbh->error;
	$c->session(id => $id);
	return Mojo::ByteStream::->new(qq{$challenge = <input name="captcha" type="text" required>});
};

under '/*path_' => {path_ => $config->{root_page}} => sub {
	my $c = shift;
	# normalize path
	my $path = $c->stash("path_");
	# multiple /s mean nothing
	$path =~ s{/{2,}}{/}g;
	# strip ../ in path
	$path =~ s{[^/]*/\.\./}{}g;
	# / in the end should also be sanitized
	$path =~ s{/$}{};
	$c->stash("title" => $path);
	return 1;
};

helper 'render_edit_form' => sub {
	my ($c,$edit,$path) = @_;
	my $dbh = $c->dbh;
	$dbh
		->query(
			$edit ? 'select html, src from pages where title = ? and time = (0+?) order by time desc limit 1'
			      : 'select html, src from pages where title = ? order by time desc limit 1',
			$path,
			$edit || ()
		)->into(my($html, $src))
		or return $c->render('edit', html => '', src => '', msg => 'Page/revision not found', status => 404);
	return $c->render('edit', html => $html, src => $src);
};

helper 'render_page' => sub {
	my ($c, $path, $rev) = @_;
	my $dbh = $c->dbh;
	$dbh
		->query(
			defined($rev) ? 'select who, html, time from pages where title = ? and time = (0+?)'
			              : 'select who, html, time from pages where title = ? order by time desc limit 1',
			$path, $rev // ()
		)->into(my($who, $html, $time))
		or return $c->render('edit', msg => 'Page/revision not found, create one?', src => '', html => '', status => 404);
	return $c->render('page', html => $html, who => $who, time => $time);
};

helper 'render_list_revisions' => sub {
	my ($c, $path) = @_;
	my $dbh = $c->dbh;
	my @history = $dbh
		->select('pages', [qw/time who/], { title => $path }, { -desc => 'time' })
		->arrays;
	return $c->render('edit', msg => 'Page not found', src => '', html => '', status => 404)
		unless @history;
	return $c->render('history', history => \@history);
};

get sub {
	my $c = shift;
	my $path = $c->stash("title");
	my $edit = $c->param('edit');
	my $rev = $c->param('rev');
	my $dbh = $c->dbh;
	if (defined($edit)) { # show edit form
		return $c->render_edit_form($edit, $path);
	} elsif (defined($rev)) {
		# list revisions or select a specific one
		if ($rev and looks_like_number($rev)) { # 0 and '' are not valid revisions
			return $c->render_page($path,$rev);
		} else { # asked for list of revisions
			return $c->render_list_revisions($path);
		}
	} else { # just plain view last revision
		return $c->render_page($path);
	}
};

sub process_source {
	use Mojo::Util qw(xml_escape);
	my ($path, $src) = @_;
	$src = $config->{preprocess_src}($src) if $config->{preprocess_src};
	$src =~ s{ # giant regular expressions! shock, horrors!
		\[\[   # wikilink begins with [[
		([^|\]]+) # required part (page name) with no ] or | inside allowed
		(?:    # optional part: |link_text
		 \|
		 ([^\]]+)
		)?
		\]\]
	}{
		my ($href, $text) = ($1, $2);
		'<a href="'.Mojo::URL::->new(
			  ($href =~ m[^/]) ? $href # absolute link
			: ($href =~ m[^\.\.\/]) ? "/" # sibling link
				. (($path =~ m[(.*/)[^/]+$])[0] || '') # empty on root page
				. ($href =~ m[^\.\.\/(.*)])[0]
			: "/$path/$href" # child link
		)
		.'">'.xml_escape(
			$text || ($href =~ m[([^/]+)$])[0]
		).'</a>';
	}gxe;
	return textile($src);
}

helper insert_page_revision => sub {
	my $c = shift;
	my ($path, $src, $who) = @_;
	(my $parent = $path) =~ s{/[^/]+$}{};
	my $html = process_source($path,$src);
	my $time = time;
	return $c->dbh->insert('pages', { title => $path, who => $who, src => $src, html => $html, time => $time, parent => $parent })
		? $time
		: 0;
};

helper handle_edit_page => sub {
	my ($c,$src) = @_;
	return $c->render('edit', msg => 'Invalid request (CSRF)', src => $src, html => '', status => 403)
		if $c->validation->csrf_protect->has_error;
	return $c->render('edit', msg => 'Invadid CAPTCHA', src => $src, html => '', status => 403)
		unless $c->check_human;
	my $path = $c->stash("title");
	my $preview = $c->param("preview");
	my $exit = $c->param("exit");
	if ($preview) { # no save, no redirect
		return $c->render('edit', html => process_source($path,$src), src => $src, msg => "Preview mode");
	}
	# else save the data and decide where to redirect
	my $time = $c->insert_page_revision($path, $src, $c->whois)
		or return $c->render('edit', html => process_source($path,$src), src => $src, msg => "Database returned error, please retry", status => 500);
	return $c->redirect_to($c->url_for("/$path")->query($exit ? 'rev' : 'edit', $time));
};

helper handle_search => sub {
	my ($c,$search) = @_;
	my $dbh = $c->dbh;
	my $results = $dbh->query("
		select title, snip
		from pages join
			(
				select
					docid as idxid,
					snippet(ftsindex) as snip,
					searchrank(matchinfo(ftsindex,'pcx'),0.5,1.0) as rkval
				from ftsindex
				where src match ?
			)
			on pages.rowid = idxid
		order by rkval desc
		;
	", $search) or die $dbh->error;
	# process_source to make sure there are no HTML injections, but keep HTML from SQLite snippet function
	# of course, the snippet is damaged in process
	return $c->render('search',
		results => [ map {
			$_->[1] = process_source($_->[0],$_->[1]);
			($_->[2]) = $_->[0] =~ m{([^/]+)$};
			$_
		} $results->arrays ],
		search => $search
	);
};

post sub {
	my $c = shift;
	my $src = $c->param("src");
	my $search = $c->param("search");
	if (defined($search)) {
		return $c->handle_search($search);
	}
	return $c->handle_edit_page($src);
};

push @{app->commands->namespaces}, __PACKAGE__;

app->start;
__DATA__

@@ page.html.ep
% layout 'default';
% use POSIX 'strftime';
<div class="children">
	<ul>
		<% for (children()) { %>
			<li><a href="/<%= url_for $_->[1] %>"><%= $_->[0] %></a></li>
		<% } %>
	</ul>
	<form method="post">
		<input type="submit" value="Search" id="searchbutton">
		<div id="searchtext"><input type="text" name="search"></div>
	</form>
</div>
<div class="content"><%== $html %></div>
<div class="footer">
	<a href="?edit=<%= $time %>">Edit</a>
	Revision <a href="?rev"><%= strftime "%Y-%m-%d %H:%M:%S" => localtime $time %></a> by <i><%= $who %></i>.
</div>

@@ edit.html.ep
% layout 'default';
<% if (my $msg = $self->stash("msg")) { %>
	<div class="message"><%= $msg %></div>
<% } %>
<form method="post">
	%= csrf_field;
	<div class="edit_container">
		<div class="textarea">
			<textarea id="src" name="src" rows=30><%= $src %></textarea>
		</div>
		<div class="preview">
			<%== $html %>
		</div>
	</div>
	<%= captcha_field; %><br>
	<input type="submit" name="preview" value="Preview (without saving)">
	<input type="submit" name="exit" value="Save & exit">
	<input type="submit" value="Save & continue editing"><br>
	Available syntax: <a href="http://www.w3.org/MarkUp/Guide/">HTML</a>, <a href="http://txstyle.org/">Textile</a>. Use the following style to link to other pages: <code>[[Child Page Name]], [[/Full/Path/To/Page]], [[../Sibling Page Name]], [[Page Name|Link Text]]</code>
</form>

@@ history.html.ep
% layout 'default';
% use POSIX 'strftime';
<table>
<tr>
	<th>Date&time</th>
	<th>Author</th>
</tr>
<% for my $row (@$history) { %>
	<tr>
		<td><a href="?rev=<%= $row->[0] %>"><%= strftime "%Y-%m-%d %H:%M:%S" => localtime $row->[0] %></a></td>
		<td><%= $row->[1] %></td>
	</tr>
<% } %>
</table>

@@ search.html.ep
% layout 'default';
% use POSIX 'strftime';
<div class="children">
	<form method="post">
		<input type="submit" value="Search" id="searchbutton">
		<div id="searchtext"><input type="text" name="search" value="<%= $search %>"></div>
	</form>
</div>
<h1>Search results</h1>
<% if (@$results) { %>
	<table>
	<tr>
		<th>Page</th>
		<th>Snippet</th>
	</tr>
	<% for my $result (@$results) { %>
		<% my ($path, $snippet, $title) = @$result; %>
		<tr>
			<td><a href="/<%= url_for $path %>"><%= $title %></a></td>
			<td><%== $snippet %></td>
		</tr>
	<% } %>
	</table>
<% } else { %>
	<div class="message">Not found</div>
<% } %>
The form accepts "ordinary" search engine expressions. Details: <a href="http://sqlite.org/fts3.html#section_3">Full-text Index Queries</a>

@@ exception.production.html.ep
% layout 'default';
<h1>Sorry...</h1>
<div class="message">
	A <b>very</b> serious problem has just occured. The error message, given below, has been recorded. Hopefully, someone will notice and fix it.
	<blockquote><%= $exception->message %></blockquote>
</div>
<% if (my $src = $self->param("src")) { %>
	<p>Since you were trying to make an edit, here is your source so you can copy it somewhere safe:</p>
	<textarea rows=30><%= $src %></textarea>
	<p>It has <b>not</b> been saved by the site.</p>
<% } %>

@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
	<head>
		<title><%= title_from_path() %></title>
		<style type="text/css">
			.header {
				text-align: center;
			}
			.children {
				float: right;
				width: 18%;
				background-color: #eeeeee;
				margin: 10px;
				border-radius: 5px;
			}
			#searchtext {
				overflow: hidden;
			}
			#searchtext > .input {
				width: 100%;
			}
			#searchbutton {
				float: right;
			}
			.content_block {
				text-align: justify;
				margin: 5px;
			}
			.path_links, .footer {
				border: 1px solid black;
			}
			.edit_container {
				display: block;
				overflow: auto;
				width: 100%;
			}
			.textarea, .preview {
				width: 49%;
				float: left;
				height: 100%;
			}
			textarea {
				width: 95%;
				height: 100%;
			}
			.message {
				background: #ffeeee;
				border-radius: 10px;
				border: 1px solid #110000;
				text-align: center;
			}
		</style>
	</head>
	<body>
		<div class="header"><h1><%= title_from_path() %></h1></div>
		<div class="content_block">
			<div class="path_links">
				<a href="<%= url_for "/" %>">&para;</a>
				<% for (path_links()) { %>
					/ <a href="<%= url_for $_->[1] %>"><%= $_->[0] %></a>
				<% } %>
			</div>
			<%= content %>
		</div>
  </body>
</html>
