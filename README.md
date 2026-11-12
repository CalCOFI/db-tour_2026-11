# CalCOFI.io database tour (November 2026)

The materials from the tour of the CalCOFI.io integrated database given on Thursday 12 November 2026: the slides, the notes, and the two scripts that were run live. Everything here reads the public release **v2026.11.09** ([doi:10.5281/zenodo.24083894](https://doi.org/10.5281/zenodo.24083894)) over https. There is no login and no data to download first.

## The three parts

| | what it is | link |
|---|---|---|
| **Slides** | 25 slides: the arc of the tour, a link out to every page shown, and the questions put to attendees | <https://bit.ly/calcofi-db-slides_2026-11> |
| **Notes** | the Google Doc from the invite: the agenda, the four polls, and the wish list, which stays open for requests | <https://bit.ly/calcofi-db-notes_2026-11> |
| **Repo** | this folder: the R and Python walkthroughs and a one-page guide to the tables | <https://github.com/CalCOFI/db-tour_2026-11> |

Each of the three links to the other two.

## Get the scripts

[**Download everything as a zip**](https://github.com/CalCOFI/db-tour_2026-11/archive/refs/heads/main.zip), or clone it:

```
git clone https://github.com/CalCOFI/db-tour_2026-11.git
```

| file | what |
|---|---|
| [`01_tour.R`](01_tour.R) | the R walkthrough in 15 sections, using [calcofi4r](https://calcofi.io/calcofi4r/). `[live]` marks the sections shown in the tour; the rest are take-home, and each runs on its own after sections 0 and 1 |
| [`02_tour.py`](02_tour.py) | the same in Python, in `# %%` cells, using [calcofi4py](https://calcofi.io/calcofi4py/). The two agree row for row |
| [`schema.md`](schema.md) | how the tables fit together: the core diagram, what one row of each table is, and the joins |
| `.vscode/settings.json` | points [Positron](https://positron.posit.co/) or VS Code at the Python environment below |

## Run them

Open the folder in Positron (File › Open Folder) and run one section or cell at a time with Cmd+Enter (Ctrl+Enter on Windows).

**R** (4.1 or later, for the `|>` pipe; the tour used 4.6). Section 0 of `01_tour.R` installs what is missing, calcofi4r included:

```r
install.packages("librarian")   # once
```

**Python** (the tour used 3.12), with [uv](https://docs.astral.sh/uv/):

```
uv venv --python 3.12 .venv
uv pip install --python .venv "calcofi4py @ git+https://github.com/CalCOFI/calcofi4py" pandas pyarrow gsw ipykernel
```

A whole run takes about a minute for each script once the tables are cached. Both write one small table to `data/`, which you can open in Positron's Data Explorer.

Both scripts pin `VERSION = "v2026.11.09"`, so they return the same rows next year as on the day. Drop the version (`cc_get_db()`) to read the newest release.

## Notes

- `sample_track` is in the diagram but not yet in a public release, so the [schema browser](https://calcofi.io/db-schema/), which lists public releases only, does not show it.
- Positron's Connections pane shows the connection `con`. Expanding a big table such as `obs_env` fetches it, so expand `sample` or `taxon` first.
- More, from the same starting point: [the docs](https://calcofi.io/docs/), [access the data](https://calcofi.io/docs/data-access.html), [cite this data](https://calcofi.io/docs/cite.html), [the release notes](https://storage.calcofi.io/calcofi-db/ducklake/releases/RELEASES.html).

## Questions and requests

Add to the wish list at the end of the [notes](https://bit.ly/calcofi-db-notes_2026-11), or [open an issue](https://github.com/CalCOFI/db-tour_2026-11/issues) here.

## Licence

The scripts and text here are under the [MIT licence](LICENSE). The data they read keep their own licences and citations: see [cite this data](https://calcofi.io/docs/cite.html).
