use std::{env, path::PathBuf};

use reader_core::{build_embeddings, build_sqlite_index, ReaderPaths};

fn main() -> anyhow::Result<()> {
    let reader_root = env::var("READER_ROOT")
        .map(PathBuf::from)
        .unwrap_or(env::current_dir()?);
    let paths = ReaderPaths::from_reader_root(reader_root)?;

    // `reader-index embeddings` runs the heavy, opt-in vector pass over an
    // already-built index. Default (no arg) is the fast, model-free metadata
    // + FTS build.
    if env::args().nth(1).as_deref() == Some("embeddings") {
        println!("embedding {} (downloads/loads BGE-M3 ~2.3 GB)…", paths.vault.display());
        let n = build_embeddings(&paths)?;
        println!("embedded {n} entries into entry_vectors");
        return Ok(());
    }

    println!("scanning {}", paths.vault.display());
    let stats = build_sqlite_index(&paths)?;
    println!("found {} md files", stats.scanned_files);
    if stats.source_pdfs > 0 {
        println!("sources/ has {} PDFs", stats.source_pdfs);
    }
    println!(
        "wrote {} entries -> {}",
        stats.entries,
        stats
            .output
            .strip_prefix(&paths.workspace_root)
            .unwrap_or(&stats.output)
            .display()
    );
    println!("by type: {:?}", stats.by_type);
    if stats.skipped_frontmatter_without_type > 0 {
        println!(
            "skipped {} files with frontmatter but no usable type",
            stats.skipped_frontmatter_without_type
        );
    }
    Ok(())
}
