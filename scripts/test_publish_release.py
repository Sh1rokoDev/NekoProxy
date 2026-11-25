"""Exercise the release lifecycle against simulated Git and GitHub commands."""

import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("publish-release.py")
SPEC = importlib.util.spec_from_file_location("publish_release", SCRIPT)
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)
REPOSITORY = "test/NekoProxy"
ENDPOINT = f"repos/{REPOSITORY}/releases"
COMMIT = "1" * 40
ANNOTATION = "2" * 40
OTHER_SHA = "3" * 40


class ReleaseRemote:
    def __init__(self):
        self.tags = {}
        self.releases = {}
        self.next_release_id = 1
        self.latest_tag = None
        self.writes = []
        self.publish_error = False
        self.corrupt_published_assets = False
        self.move_during_upload = False
        self.move_before_delete = None

    def tag(self, name, sha=COMMIT, peeled=None):
        ref = f"refs/tags/{name}"
        self.tags[ref] = sha
        if peeled:
            self.tags[f"{ref}^{{}}"] = peeled

    def release(self, tag, **changes):
        release = {
            "id": self.next_release_id,
            "tag_name": tag,
            "name": f"NekoProxy {tag}",
            "draft": False,
            "prerelease": False,
            "immutable": False,
            "html_url": f"https://example.invalid/releases/{tag}",
            "assets": [],
            **changes,
        }
        self.next_release_id += 1
        self.releases[release["id"]] = release
        return release["id"]

    def versions(self):
        return {
            ref.removeprefix("refs/tags/")
            for ref in self.tags
            if not ref.endswith("^{}")
        } | {release["tag_name"] for release in self.releases.values()}

    def __call__(self, *command):
        match command:
            case ("git", "rev-parse", "HEAD"):
                return COMMIT
            case ("git", "ls-remote", "--tags", "origin", *refs):
                return "\n".join(
                    f"{sha}\t{ref}"
                    for ref, sha in self.tags.items()
                    if not refs or ref in refs
                )
            case ("git", "push", lease, "origin", target):
                ref = target.removeprefix(":")
                tag = ref.removeprefix("refs/tags/")
                if self.move_before_delete == tag:
                    self.tags[ref] = OTHER_SHA
                if lease != f"--force-with-lease={ref}:{self.tags[ref]}":
                    raise subprocess.CalledProcessError(1, command)
                assert not any(
                    release["tag_name"] == tag and release["immutable"]
                    for release in self.releases.values()
                )
                del self.tags[ref]
                self.tags.pop(f"{ref}^{{}}", None)
                self.writes.append(("delete tag", tag))
                return ""
            case ("gh", "api", "--paginate", "--slurp", endpoint):
                assert endpoint == f"{ENDPOINT}?per_page=100"
                listed = list(self.releases.values())
                return json.dumps(
                    [listed[i : i + 100] for i in range(0, len(listed), 100)] or [[]]
                )
            case ("gh", "api", "--method", "DELETE", endpoint):
                release = self.releases.pop(int(endpoint.rsplit("/", 1)[1]))
                if self.latest_tag == release["tag_name"]:
                    self.latest_tag = None
                self.writes.append(("delete release", release["tag_name"]))
                return ""
            case (
                "gh",
                "release",
                "create",
                tag,
                "--verify-tag",
                "--draft",
                "--target",
                commit,
                "--title",
                title,
                "--notes-file",
                _,
                *assets,
            ):
                assert commit == COMMIT
                assert title == f"NekoProxy {tag}"
                assert f"refs/tags/{tag}" in self.tags
                assert not any(
                    release["tag_name"] == tag for release in self.releases.values()
                )
                if self.publish_error:
                    raise subprocess.CalledProcessError(1, command)
                self.release(
                    tag,
                    draft=True,
                    assets=[
                        {
                            "name": Path(asset).name,
                            "size": Path(asset).stat().st_size,
                            "state": "uploaded",
                        }
                        for asset in assets
                    ],
                )
                self.writes.append(("create draft", tag))
                if self.move_during_upload:
                    self.tag(tag, OTHER_SHA, COMMIT)
                return ""
            case (
                "gh",
                "release",
                "view",
                tag,
                "--json",
                "databaseId,tagName,isDraft,assets",
            ):
                release = next(
                    release
                    for release in self.releases.values()
                    if release["tag_name"] == tag
                )
                return json.dumps(
                    {
                        "databaseId": release["id"],
                        "tagName": tag,
                        "isDraft": release["draft"],
                        "assets": release["assets"],
                    }
                )
            case (
                "gh",
                "api",
                "--method",
                "PATCH",
                endpoint,
                "-F",
                "draft=false",
                "-f",
                latest,
            ):
                release = self.releases[int(endpoint.rsplit("/", 1)[1])]
                release["draft"] = False
                if latest == "make_latest=true":
                    self.latest_tag = release["tag_name"]
                self.writes.append(("publish", release["tag_name"], latest))
                return json.dumps(release)
            case ("gh", "api", endpoint) if endpoint.startswith(f"{ENDPOINT}/tags/"):
                tag = endpoint.rsplit("/", 1)[1]
                release = next(
                    release
                    for release in self.releases.values()
                    if release["tag_name"] == tag
                )
                assert not release["draft"]
                if self.corrupt_published_assets:
                    release["assets"] = []
                return json.dumps(release)
            case _:
                raise AssertionError(f"Unmocked command: {command}")


class PublishReleaseTest(unittest.TestCase):
    def setUp(self):
        self.remote = ReleaseRemote()
        temp = self.enterContext(tempfile.TemporaryDirectory())
        self.notes = Path(temp, "release-notes.md")
        self.notes.write_text("Upstream versions.", encoding="utf-8")
        self.asset = Path(temp, "NekoProxy-1.0.0+123abcd-windows-x64.zip")
        self.asset.write_bytes(b"test release asset")
        self.enterContext(patch.object(publisher, "run", side_effect=self.remote))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def publish(self, tag, event_sha=COMMIT):
        publisher.publish(REPOSITORY, tag, event_sha, self.notes, [self.asset])

    def add_released_versions(self, *versions):
        for tag in versions:
            self.remote.tag(tag)
            self.remote.release(tag)

    def test_retains_five_versions_across_pages_and_sweeps_either_kind_of_orphan(self):
        for number in range(100):
            self.remote.release(f"non-release-{number}")
        self.add_released_versions("v1.9.0", "v1.10.0")
        self.remote.tag("v1.6.0")
        self.remote.release("v1.6.0", name="Renamed old release")
        for tag in ("v1.4.0", "v1.8.0", "v1.11.0"):
            self.remote.tag(tag)
        for tag in ("v1.5.0", "v1.7.0"):
            self.remote.release(tag)
        for tag, properties in (
            ("v1.0.0", {"draft": True}),
            ("v1.0.1", {"prerelease": True}),
            ("v1.0.3-rc.1", {}),
        ):
            self.remote.tag(tag)
            self.remote.release(tag, **properties)

        self.publish("v1.11.0")

        protected = {"v1.0.0", "v1.0.1", "v1.0.3-rc.1"}
        remaining = self.remote.versions() - protected
        self.assertEqual(
            {tag for tag in remaining if tag.startswith("v")},
            {"v1.7.0", "v1.8.0", "v1.9.0", "v1.10.0", "v1.11.0"},
        )
        self.assertTrue(protected <= self.remote.versions())
        self.assertEqual(
            self.remote.writes,
            [
                ("create draft", "v1.11.0"),
                ("publish", "v1.11.0", "make_latest=true"),
                ("delete tag", "v1.6.0"),
                ("delete release", "v1.6.0"),
                ("delete release", "v1.5.0"),
                ("delete tag", "v1.4.0"),
            ],
        )

    def test_forced_older_tag_reuses_its_ref_and_one_of_five_slots(self):
        current = "v1.1.0"
        self.add_released_versions(*(f"v1.{number}.0" for number in range(3, 11)))
        self.remote.tag(current, ANNOTATION, COMMIT)
        self.remote.latest_tag = "v1.10.0"
        old_release_id = self.remote.release(current, name="Renamed release")

        self.publish(current, ANNOTATION)

        self.assertNotIn(old_release_id, self.remote.releases)
        self.assertEqual(self.remote.latest_tag, "v1.10.0")
        self.assertEqual(self.remote.tags[f"refs/tags/{current}"], ANNOTATION)
        self.assertEqual(
            self.remote.versions(), {current, "v1.7.0", "v1.8.0", "v1.9.0", "v1.10.0"}
        )
        self.assertEqual(
            self.remote.writes[:3],
            [
                ("delete release", current),
                ("create draft", current),
                ("publish", current, "make_latest=false"),
            ],
        )

    def test_newer_orphan_tags_cannot_evict_the_newest_published_version(self):
        self.add_released_versions("v1.8.0")
        for number in range(9, 15):
            self.remote.tag(f"v1.{number}.0")
        self.remote.tag("v1.7.0")

        self.publish("v1.7.0")

        self.assertEqual(
            self.remote.versions(),
            {"v1.7.0", "v1.8.0", "v1.12.0", "v1.13.0", "v1.14.0"},
        )

    def test_rejects_stale_tag_push_before_any_writes(self):
        self.add_released_versions("v1.1.0")
        self.remote.tag("v1.1.0", OTHER_SHA, OTHER_SHA)
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            self.publish("v1.1.0", ANNOTATION)
        self.assertEqual(self.remote.writes, [])

    def test_tag_move_during_upload_prevents_publishing_and_pruning(self):
        self.remote.tag("v1.10.0", ANNOTATION, COMMIT)
        self.remote.move_during_upload = True

        with self.assertRaisesRegex(RuntimeError, "moved or was deleted"):
            self.publish("v1.10.0")
        self.assertEqual(self.remote.writes, [("create draft", "v1.10.0")])

    def test_immutable_release_is_not_replaced(self):
        self.remote.tag("v1.10.0")
        self.remote.release("v1.10.0", immutable=True)

        with self.assertRaisesRegex(RuntimeError, "immutable Release"):
            self.publish("v1.10.0")
        self.assertEqual(self.remote.writes, [])

    def test_replaces_a_same_tag_draft_left_by_an_interrupted_run(self):
        self.remote.tag("v1.10.0")
        old_release_id = self.remote.release("v1.10.0", draft=True)

        self.publish("v1.10.0")

        self.assertNotIn(old_release_id, self.remote.releases)
        self.assertEqual(self.remote.writes[0], ("delete release", "v1.10.0"))

    def test_publish_failure_does_not_retire_history(self):
        self.add_released_versions(*(f"v1.{number}.0" for number in range(1, 7)))
        self.remote.tag("v1.10.0")
        self.remote.publish_error = True

        with self.assertRaises(subprocess.CalledProcessError):
            self.publish("v1.10.0")
        self.assertEqual(self.remote.writes, [])
        self.assertEqual(len(self.remote.releases), 6)

    def test_unverified_published_assets_do_not_retire_history(self):
        self.add_released_versions(*(f"v1.{number}.0" for number in range(1, 7)))
        self.remote.tag("v1.10.0")
        self.remote.corrupt_published_assets = True

        with self.assertRaisesRegex(RuntimeError, "expected set of uploaded assets"):
            self.publish("v1.10.0")
        self.assertEqual(
            self.remote.writes,
            [("create draft", "v1.10.0"), ("publish", "v1.10.0", "make_latest=true")],
        )
        self.assertEqual(len(self.remote.releases), 7)

    def test_retires_an_immutable_release_before_its_locked_tag(self):
        self.add_released_versions(*(f"v1.{number}.0" for number in range(2, 6)))
        self.remote.tag("v1.1.0")
        self.remote.release("v1.1.0", immutable=True)
        self.remote.tag("v1.10.0")

        self.publish("v1.10.0")

        self.assertEqual(
            self.remote.writes[-2:],
            [
                ("delete release", "v1.1.0"),
                ("delete tag", "v1.1.0"),
            ],
        )

    def test_retention_lease_leaves_a_moved_tag_and_its_release_present(self):
        self.add_released_versions(*(f"v1.{number}.0" for number in range(1, 6)))
        self.remote.tag("v1.10.0")
        self.remote.move_before_delete = "v1.1.0"

        with self.assertRaises(subprocess.CalledProcessError):
            self.publish("v1.10.0")
        self.assertEqual(self.remote.tags["refs/tags/v1.1.0"], OTHER_SHA)
        self.assertTrue(
            any(
                release["tag_name"] == "v1.1.0"
                for release in self.remote.releases.values()
            )
        )


if __name__ == "__main__":
    unittest.main()
