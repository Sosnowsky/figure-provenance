"""Record, beside each saved figure, what made it: for whoever -- often an AI -- has to change it later.

``save(fig, path)`` writes the figure, and its entry in the ``provenance.json`` of the same folder:
the function that drew it, its arguments, the line that called it, the command that ran, the git
commit of the code with the files that differed from it, the date, and the function's docstring as
the figure's purpose. The function is known when it is decorated with ``@provenance``; without that,
the entry names the code that called ``save``.

    from figure_provenance import provenance, save

    @provenance
    def fig_tracks(ds, pixels):
        \"\"\"What the figure shows, and why it is drawn the way it is.\"\"\"
        fig, ax = plt.subplots()
        ...
        return fig

    save(fig_tracks(ds, pixels), "figures/tracks.pdf", bbox_inches="tight")
"""

import datetime
import functools
import inspect
import json
import numbers
import os
import shlex
import subprocess
import sys
import warnings
from collections.abc import Mapping
from enum import Enum
from pathlib import Path

try:
    import fcntl
except ImportError:  # Windows: no lock, so two processes must not save into one folder at once
    fcntl = None

__all__ = ["MANIFEST", "provenance", "save"]

MANIFEST = "provenance.json"
ABOUT = (
    "Written by the figure_provenance package (https://github.com/Sosnowsky/figure-provenance) each time "
    "a figure in this folder is saved, one entry per "
    "file. 'producer' is the function that drew it, a path inside the git repository 'repo' (remote "
    "'remote') at 'commit'; 'uncommitted' lists the files that differed from that commit when it ran. "
    "'call' gives its arguments, 'called_from' the line that called it, 'command' what was run, from "
    "'cwd'. 'purpose' is the producer's docstring. To change a figure, edit the producer and its "
    "docstring and rerun it: an edit to the file itself is lost on the next run."
)
_ATTR = "_figure_provenance"


def provenance(func):
    """Decorate a function returning a figure, or a tuple starting with one, so ``save`` knows what drew it."""

    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        result = func(*args, **kwargs)
        fig = result[0] if isinstance(result, (tuple, list)) and result else result
        if hasattr(fig, "savefig"):
            try:
                bound = inspect.signature(func).bind(*args, **kwargs)
                call = ", ".join(f"{k}={_describe(v)}" for k, v in bound.arguments.items())
            except TypeError:
                call = "..."
            caller = sys._getframe(1)
            setattr(fig, _ATTR, {
                "file": func.__code__.co_filename,
                "name": func.__qualname__,
                "doc": inspect.getdoc(func),
                "call": f"{func.__name__}({call})",
                "caller": (caller.f_code.co_filename, caller.f_lineno, caller.f_code.co_name),
            })
        return result

    return wrapper


def save(fig, path, *, stacklevel=1, **kwargs):
    """``fig.savefig(path, **kwargs)``, then the figure's entry in the ``provenance.json`` beside it.

    Without ``@provenance`` on the function that drew ``fig``, the entry names the code that called
    ``save``; a project's own wrapper around ``save`` passes ``stacklevel=2``, so that it names the
    wrapper's caller rather than the wrapper.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, **kwargs)
    made = getattr(fig, _ATTR, None)
    if made is None:
        frame = sys._getframe(stacklevel)
        name = frame.f_code.co_name
        made = {
            "file": frame.f_code.co_filename,
            "name": None if name == "<module>" else name,
            "doc": _doc(frame),
            "call": None,
            "caller": (frame.f_code.co_filename, frame.f_lineno, name),
        }
    entry = _entry(made)
    if not entry["purpose"]:
        warnings.warn(f"{entry['producer']} has no docstring: {MANIFEST} will not say what {path.name} is for",
                      stacklevel=stacklevel + 1)
    _record(path, entry)
    return path


def _doc(frame):
    """The docstring of the function (or module) ``frame`` runs, if it can be found."""
    if frame.f_code.co_name == "<module>":
        doc = frame.f_globals.get("__doc__")
        return inspect.cleandoc(doc) if doc else None
    func = frame.f_globals.get(frame.f_code.co_name)
    if func is not None and getattr(inspect.unwrap(func), "__code__", None) is frame.f_code:
        return inspect.getdoc(func)
    return None  # a method or a nested function: decorate it to have its docstring


def _entry(made):
    root = _root(made["file"])
    producer = _rel(made["file"], root) + (f":{made['name']}" if made["name"] else "")
    file, line, name = made["caller"]
    entry = {
        "producer": producer,
        "call": made["call"],
        "called_from": f"{_rel(file, root)}:{line} ({name})",
        "command": shlex.join(getattr(sys, "orig_argv", [sys.executable, *sys.argv])),
        "cwd": _rel(os.getcwd(), root),
        "date": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    if root is not None:
        status = _git(root, "status", "--porcelain", "--untracked-files=no") or ""
        uncommitted = [line[3:] for line in status.splitlines() if line.strip()]
        rel = _rel(made["file"], root)
        if _git(root, "ls-files", "--error-unmatch", "--", rel) is None:
            uncommitted.append(f"{rel} (untracked)")
        entry.update(
            repo=root.name,
            remote=(_git(root, "remote", "get-url", "origin") or "").strip() or None,
            commit=(_git(root, "rev-parse", "HEAD") or "").strip() or None,
            uncommitted=uncommitted,
        )
    entry["purpose"] = made["doc"]
    return entry


def _record(path, entry):
    manifest = path.parent / MANIFEST
    with open(manifest, "a+", encoding="utf-8") as fh:
        if fcntl is not None:
            fcntl.flock(fh, fcntl.LOCK_EX)  # two processes saving into one folder: neither entry lost
        fh.seek(0)
        text = fh.read()
        try:
            figures = json.loads(text).get("figures", {}) if text.strip() else {}
        except json.JSONDecodeError as err:
            raise ValueError(f"{manifest} is not valid JSON: fix or delete it") from err
        figures[path.name] = entry
        fh.seek(0)
        fh.truncate()
        json.dump({"about": ABOUT, "figures": dict(sorted(figures.items()))}, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def _describe(value, limit=120):
    """An argument as the manifest gives it: its repr when that is short and plain data, else its type."""
    if _plain(value):
        text = repr(value)
        return text if len(text) <= limit else text[: limit - 3] + "..."
    kind = type(value).__name__
    shape = getattr(value, "shape", None)
    if isinstance(shape, tuple):
        return f"<{kind} {shape}>"
    sizes = getattr(value, "sizes", None)  # an xarray Dataset
    if isinstance(sizes, Mapping) and sizes:
        return f"<{kind} {dict(sizes)}>"
    return f"<{kind}>"


def _plain(value):
    if isinstance(value, (list, tuple, set, frozenset)):
        return all(_plain(v) for v in value)
    if isinstance(value, dict):
        return all(_plain(k) and _plain(v) for k, v in value.items())
    return value is None or isinstance(value, (str, bytes, numbers.Number, Path, Enum))


def _git(root, *args):
    try:
        out = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout if out.returncode == 0 else None


def _root(file):
    """The root of the git repository holding ``file``, or None."""
    file = Path(file)
    if not file.is_file():  # "<stdin>", a notebook cell
        return None
    root = _git(file.resolve().parent, "rev-parse", "--show-toplevel")
    return Path(root.strip()) if root else None


def _rel(path, root):
    path = Path(path).resolve()
    if root is not None and path.is_relative_to(root):
        return path.relative_to(root).as_posix() or "."
    return str(path)
