use anyhow::{Context, Result, bail};
use duckdb::Connection;
use scryer_prolog::{LeafAnswer, Machine, MachineBuilder, StreamConfig, Term};
use std::io::{BufRead, Write};

struct Args {
    rules:       String,
    sql:         String,
    entry_name:  String,
    entry_arity: u8,
    subject:     Option<String>,
    repl:        bool,
}

fn parse_args() -> Result<Args> {
    let mut rules = String::from("rules.pl");
    let mut sql   = String::from("queries.sql");
    let mut entry_raw: Option<String> = None;
    let mut subject: Option<String> = None;
    let mut repl = false;
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--rules" => rules = it.next().context("--rules needs path")?,
            "--sql"   => sql   = it.next().context("--sql needs path")?,
            "--entry" => entry_raw = Some(it.next().context("--entry needs name/arity")?),
            "--repl"  => repl  = true,
            "-h" | "--help" => {
                eprintln!("usage: scryql --rules PATH --sql PATH --entry NAME/ARITY [--repl] [<subject>]");
                eprintln!("  --entry NAME/1   side-effect mode (rule emits via format/2)");
                eprintln!("  --entry NAME/2   capture-result mode: NAME(Subject, R), prints R");
                eprintln!("  with subject:    run <entry> once and exit");
                eprintln!("  with --repl:     after running, drop into a REPL");
                eprintln!("  no subject:      drop straight into REPL");
                std::process::exit(0);
            }
            other if other.starts_with("--") => bail!("unknown flag: {other}"),
            other => subject = Some(other.to_string()),
        }
    }
    let entry = entry_raw.context("missing --entry NAME/ARITY")?;
    let (entry_name, entry_arity) = parse_entry_spec(&entry)?;
    Ok(Args { rules, sql, entry_name, entry_arity, subject, repl })
}

fn parse_entry_spec(s: &str) -> Result<(String, u8)> {
    let (name, arity_s) = s.split_once('/').context("--entry must be NAME/ARITY")?;
    let arity: u8 = arity_s.parse().context("arity must be a small integer")?;
    if arity != 1 && arity != 2 { bail!("--entry arity must be 1 or 2 (got {arity})"); }
    if name.is_empty() { bail!("--entry needs a predicate name before /"); }
    Ok((name.to_string(), arity))
}

fn main() -> Result<()> {
    let args = parse_args()?;

    let sql_text = std::fs::read_to_string(&args.sql)
        .with_context(|| format!("reading {}", args.sql))?;
    let (setup, rows) = split_sections(&sql_text);

    let conn = Connection::open_in_memory()?;
    if !setup.is_empty() { conn.execute_batch(&setup)?; }

    let rules = std::fs::read_to_string(&args.rules)
        .with_context(|| format!("reading {}", args.rules))?;

    let mut machine = MachineBuilder::new()
        .with_streams(StreamConfig::stdio())
        .build();
    machine.consult_module_string("user", rules);

    match &args.subject {
        Some(subject) => {
            let facts = facts_for(&conn, &rows, subject)?;
            machine.consult_module_string("user", facts);
            run_entry(&mut machine, &args.entry_name, args.entry_arity, subject)?;
            if args.repl { repl(&mut machine, &conn, &rows, &args.entry_name); }
        }
        None => repl(&mut machine, &conn, &rows, &args.entry_name),
    }
    Ok(())
}

fn run_entry(machine: &mut Machine, name: &str, arity: u8, subject: &str) -> Result<()> {
    match arity {
        1 => {
            let q = format!("{name}('{subject}').");
            run_for_side_effect(machine, &q)
        }
        2 => {
            let q = format!("{name}('{subject}', R).");
            let r = run_for_term(machine, &q, "R")?;
            println!("{}", write_term(&r));
            Ok(())
        }
        _ => bail!("unsupported arity {arity}"),
    }
}

/// Split SQL by `-- @setup` / `-- @row` markers.
fn split_sections(src: &str) -> (String, Vec<String>) {
    let mut setup = String::new();
    let mut rows  = Vec::new();
    let mut buf   = String::new();
    let mut mode: Option<&str> = None;
    let flush = |mode: &Option<&str>, buf: &mut String, setup: &mut String, rows: &mut Vec<String>| {
        let chunk = std::mem::take(buf).trim().to_string();
        if chunk.is_empty() { return; }
        match mode {
            Some("setup") => { setup.push_str(&chunk); setup.push('\n'); }
            Some("row")   => rows.push(chunk),
            _             => {}
        }
    };
    for line in src.lines() {
        let t = line.trim_start();
        if let Some(rest) = t.strip_prefix("-- @") {
            flush(&mode, &mut buf, &mut setup, &mut rows);
            mode = match rest.split_whitespace().next().unwrap_or("") {
                "setup" => Some("setup"),
                "row"   => Some("row"),
                _       => None,
            };
            continue;
        }
        if t.starts_with("--") { continue; }
        buf.push_str(line);
        buf.push('\n');
    }
    flush(&mode, &mut buf, &mut setup, &mut rows);
    (setup, rows)
}

fn facts_for(conn: &Connection, rows: &[String], subject: &str) -> Result<String> {
    let mut out = String::new();
    for sql in rows {
        let mut s = conn.prepare(sql.trim_end_matches(';'))?;
        let mut r = s.query([subject])?;
        while let Some(row) = r.next()? {
            let clause: String = row.get(0)?;
            out.push_str(&clause);
            out.push('\n');
        }
    }
    Ok(out)
}

fn run_for_side_effect(machine: &mut Machine, query: &str) -> Result<()> {
    for answer in machine.run_query(query) {
        match answer {
            Ok(LeafAnswer::True) | Ok(LeafAnswer::LeafAnswer { .. }) => return Ok(()),
            Ok(LeafAnswer::False) => bail!("query failed: {query}"),
            Ok(LeafAnswer::Exception(t)) => bail!("prolog exception: {t:?}"),
            Err(e) => bail!("query error: {e:?}"),
        }
    }
    Ok(())
}

fn run_for_term(machine: &mut Machine, query: &str, var: &str) -> Result<Term> {
    for answer in machine.run_query(query) {
        match answer {
            Ok(LeafAnswer::LeafAnswer { bindings, .. }) => {
                if let Some(t) = bindings.get(var) { return Ok(t.clone()); }
            }
            Ok(LeafAnswer::True)  => bail!("query succeeded with no binding for {var}"),
            Ok(LeafAnswer::False) => bail!("query failed: {query}"),
            Ok(LeafAnswer::Exception(t)) => bail!("prolog exception: {t:?}"),
            Err(e) => bail!("query error: {e:?}"),
        }
    }
    bail!("no answers from {query}")
}

fn repl(machine: &mut Machine, conn: &Connection, rows: &[String], entry: &str) {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    print!("?- "); stdout.flush().ok();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let q = line.trim();
        if q.is_empty() { print!("?- "); stdout.flush().ok(); continue; }
        if q == "halt." || q == "halt" { break; }

        // Intercept calls of the form `<entry>('arg').` — fetch facts for `arg`
        // before running the query so the rule sees the right fact base.
        if let Some(subject) = parse_entry_call(q, entry) {
            match facts_for(conn, rows, subject) {
                Ok(facts) => machine.consult_module_string("user", facts),
                Err(e)    => { println!("fetch error: {e}"); print!("?- "); stdout.flush().ok(); continue; }
            }
        }

        let q = if q.ends_with('.') { q.to_string() } else { format!("{q}.") };
        let mut answers = 0usize;
        for answer in machine.run_query(&q) {
            answers += 1;
            match answer {
                Ok(LeafAnswer::True) => println!("true."),
                Ok(LeafAnswer::False) => println!("false."),
                Ok(LeafAnswer::LeafAnswer { bindings, .. }) => {
                    if bindings.is_empty() {
                        println!("true.");
                    } else {
                        let parts: Vec<String> = bindings.iter()
                            .map(|(v, t)| format!("{v} = {}", write_term(t)))
                            .collect();
                        println!("{}.", parts.join(", "));
                    }
                }
                Ok(LeafAnswer::Exception(t)) => println!("exception: {}", write_term(&t)),
                Err(e) => println!("error: {e:?}"),
            }
        }
        if answers == 0 { println!("false."); }
        print!("?- "); stdout.flush().ok();
    }
    println!();
}

/// Recognise `entry('subject').` (with or without the trailing `.`, with or
/// without single-quotes around the subject). Returns the unquoted subject.
fn parse_entry_call<'a>(line: &'a str, entry: &str) -> Option<&'a str> {
    let line = line.trim().trim_end_matches('.').trim();
    let rest = line.strip_prefix(entry)?.trim_start();
    let inside = rest.strip_prefix('(')?;
    let closing = inside.rfind(')')?;
    let arg = inside[..closing].trim();
    let arg = arg.strip_prefix('\'').unwrap_or(arg).strip_suffix('\'').unwrap_or(arg);
    if arg.is_empty() || arg.contains(',') { return None; }
    Some(arg)
}

/// Minimal canonical writer for terms surfaced in REPL bindings.
fn write_term(t: &Term) -> String {
    match t {
        Term::Atom(a)   => a.clone(),
        Term::String(s) => format!("\"{s}\""),
        Term::Compound(name, args) => {
            let inner: Vec<String> = args.iter().map(write_term).collect();
            format!("{name}({})", inner.join(", "))
        }
        Term::List(items) => {
            let inner: Vec<String> = items.iter().map(write_term).collect();
            format!("[{}]", inner.join(", "))
        }
        _ => format!("{t:?}"),
    }
}
