use std::{env, path::PathBuf};

use reader_core::{build_sqlite_index, ReaderPaths};

fn main() -> anyhow::Result<()> {
    let reader_root = env::var("READER_ROOT")
        .map(PathBuf::from)
        .unwrap_or(env::current_dir()?);
    let paths = ReaderPaths::from_reader_root(reader_root)?;

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
