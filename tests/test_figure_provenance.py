import importlib.util
import json
import subprocess

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pytest  # noqa: E402

import figure_provenance as fp  # noqa: E402


@fp.provenance
def fig_line(values, scale=1.0, label=None):
    """A line, for the tests."""
    fig, ax = plt.subplots()
    ax.plot(np.asarray(values) * scale)
    return fig


def draw_and_save(path):
    """Saved without the decorator."""
    fp.save(plt.figure(), path)


def wrapped_save(path):
    fp.save(plt.figure(), path, stacklevel=2)


def read(folder):
    return json.loads((folder / fp.MANIFEST).read_text())


def test_decorated(tmp_path):
    fp.save(fig_line([1, 2, 3], scale=2.0), tmp_path / "line.pdf")
    assert (tmp_path / "line.pdf").is_file()
    e = read(tmp_path)["figures"]["line.pdf"]
    assert e["producer"].endswith("test_figure_provenance.py:fig_line")
    assert e["call"] == "fig_line(values=[1, 2, 3], scale=2.0)"
    assert e["called_from"].endswith("(test_decorated)")
    assert e["purpose"] == "A line, for the tests."


def test_arguments_too_large_to_print(tmp_path):
    fp.save(fig_line(np.arange(3), label="x" * 200), tmp_path / "line.png")
    call = read(tmp_path)["figures"]["line.png"]["call"]
    assert call.startswith("fig_line(values=<ndarray (3,)>, label='xxx")
    assert call.endswith("...)")


def test_entries_accumulate(tmp_path):
    fp.save(fig_line([1]), tmp_path / "b.png")
    fp.save(fig_line([2]), tmp_path / "a.png")
    fp.save(fig_line([3]), tmp_path / "b.png")
    data = read(tmp_path)
    assert data["about"] == fp.ABOUT
    assert list(data["figures"]) == ["a.png", "b.png"]
    assert data["figures"]["b.png"]["call"] == "fig_line(values=[3])"


def test_undecorated(tmp_path):
    """The entry names whoever called save, or the wrapper's caller with stacklevel=2."""
    draw_and_save(tmp_path / "a.png")
    wrapped_save(tmp_path / "b.png")
    figures = read(tmp_path)["figures"]
    assert figures["a.png"]["producer"].endswith(":draw_and_save")
    assert figures["a.png"]["purpose"] == "Saved without the decorator."
    assert figures["a.png"]["call"] is None
    assert figures["b.png"]["producer"].endswith(":test_undecorated")


def test_warns_without_docstring(tmp_path):
    with pytest.warns(UserWarning, match="no docstring"):
        fp.save(plt.figure(), tmp_path / "a.png")


def test_git(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    (repo / "mod.py").write_text(
        "import matplotlib.pyplot as plt\n"
        "import figure_provenance as fp\n\n"
        "@fp.provenance\n"
        "def fig():\n"
        '    """In a repository."""\n'
        "    return plt.figure()\n"
    )
    (repo / "other.txt").write_text("a\n")

    def git(*args):
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                       check=True, capture_output=True)

    git("init")
    git("add", ".")
    git("commit", "-m", "first")
    (repo / "other.txt").write_text("b\n")
    spec = importlib.util.spec_from_file_location("mod", repo / "mod.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    fp.save(mod.fig(), tmp_path / "out" / "fig.png")
    e = read(tmp_path / "out")["figures"]["fig.png"]
    head = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True).stdout
    assert e["producer"] == "mod.py:fig"
    assert e["repo"] == "repo"
    assert e["commit"] == head.strip()
    assert e["uncommitted"] == ["other.txt"]
    assert e["remote"] is None
