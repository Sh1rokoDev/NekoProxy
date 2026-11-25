"""Replace a NekoProxy Release and retire older formal versions."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

RELEASE_TAG_PATTERN = re.compile(r"v([0-9]+)\.([0-9]+)\.([0-9]+)")
TAG_PREFIX = "refs/tags/"
RETAINED_VERSIONS = 5


def run(*args):
    return subprocess.run(
        args, check=True, stdout=subprocess.PIPE, text=True, encoding="utf-8"
    ).stdout


def version_key(tag):
    return tuple(map(int, RELEASE_TAG_PATTERN.fullmatch(tag).groups())), tag


def releases(endpoint):
    pages = json.loads(
        run("gh", "api", "--paginate", "--slurp", f"{endpoint}?per_page=100")
    )
    return [release for page in pages for release in page]


def managed_release(release):
    return (
        RELEASE_TAG_PATTERN.fullmatch(release["tag_name"]) is not None
        and not release["prerelease"]
    )


def remote_tags(*refs):
    lines = run("git", "ls-remote", "--tags", "origin", *refs).splitlines()
    return {ref: sha for sha, ref in map(str.split, lines)}


def require_current_ref(ref, expected_sha, refs):
    if refs.get(ref) != expected_sha:
        raise RuntimeError(
            f"{ref} moved or was deleted. Publish from the current tag push."
        )


def verify_assets(assets, expected_assets, tag):
    actual_assets = {
        asset["name"]: asset["size"] for asset in assets if asset["state"] == "uploaded"
    }
    if len(assets) != len(expected_assets) or actual_assets != expected_assets:
        raise RuntimeError(
            f"{tag} does not contain the expected set of uploaded assets."
        )


def delete_release(endpoint, release):
    run("gh", "api", "--method", "DELETE", f"{endpoint}/{release['id']}")


def prune_versions(endpoint, current_tag, current_id, pushed_sha, release_snapshot):
    current_ref = f"{TAG_PREFIX}{current_tag}"
    tags = remote_tags()
    require_current_ref(current_ref, pushed_sha, tags)
    formal_tags = {
        ref.removeprefix(TAG_PREFIX): sha
        for ref, sha in tags.items()
        if RELEASE_TAG_PATTERN.fullmatch(ref.removeprefix(TAG_PREFIX))
    }
    protected_tags = {
        release["tag_name"]
        for release in release_snapshot
        if release["draft"] or not managed_release(release)
    }
    formal_releases = {
        release["tag_name"]: release
        for release in release_snapshot
        if release["tag_name"] not in protected_tags
    }
    if formal_releases.get(current_tag, {}).get("id") != current_id:
        raise RuntimeError(
            f"The verified Release for {current_tag} changed before retention."
        )

    candidates = (formal_tags.keys() | formal_releases.keys()) - protected_tags
    ordered = sorted(candidates, key=version_key, reverse=True)
    # A backfill consumes a slot. Higher orphan tags cannot evict the
    # newest published version, which also consumes a slot.
    retained = {current_tag, max(formal_releases, key=version_key)}
    for tag in ordered:
        if len(retained) == RETAINED_VERSIONS:
            break
        retained.add(tag)

    for tag in ordered:
        if tag in retained:
            continue

        require_current_ref(current_ref, pushed_sha, remote_tags(current_ref))
        ref = f"{TAG_PREFIX}{tag}"
        release = formal_releases.get(tag)
        print(f"Retiring {tag}.", flush=True)
        # Immutable Releases lock the tag until the Release is removed.
        if release and release.get("immutable"):
            delete_release(endpoint, release)
            release = None
        if tag in formal_tags:
            # A Git lease protects an older ref that was moved after listing it.
            run(
                "git",
                "push",
                f"--force-with-lease={ref}:{formal_tags[tag]}",
                "origin",
                f":{ref}",
            )
        if release:
            delete_release(endpoint, release)


def publish(repository, tag, event_sha, notes, asset_paths):
    if not RELEASE_TAG_PATTERN.fullmatch(tag):
        raise RuntimeError(f"Expected a formal vX.Y.Z release tag, got {tag!r}.")
    expected_assets = {path.name: path.stat().st_size for path in asset_paths}
    if len(expected_assets) != len(asset_paths) or not all(expected_assets.values()):
        raise RuntimeError("Release assets must be nonempty files with unique names.")

    ref = f"{TAG_PREFIX}{tag}"
    peeled_ref = f"{ref}^{{}}"
    tags = remote_tags(ref, peeled_ref)
    pushed_sha = tags.get(ref)
    commit = run("git", "rev-parse", "HEAD").strip()
    # An annotated tag has its own SHA. GitHub can report the tip commit.
    if (
        not pushed_sha
        or tags.get(peeled_ref, pushed_sha) != commit
        or event_sha not in (pushed_sha, commit)
    ):
        raise RuntimeError(
            f"{ref} does not match this tag push and its checked-out commit."
        )

    endpoint = f"repos/{repository}/releases"
    existing_releases = releases(endpoint)
    replaced_releases = [
        release for release in existing_releases if release["tag_name"] == tag
    ]
    for release in replaced_releases:
        if release.get("immutable"):
            raise RuntimeError(
                f"{tag} has an immutable Release and cannot be replaced."
            )

    has_newer_release = any(
        not release["draft"]
        and managed_release(release)
        and version_key(release["tag_name"]) > version_key(tag)
        for release in existing_releases
    )

    for release in replaced_releases:
        require_current_ref(ref, pushed_sha, remote_tags(ref))
        print(f"Replacing the existing Release and assets for {tag}.", flush=True)
        delete_release(endpoint, release)

    require_current_ref(ref, pushed_sha, remote_tags(ref))
    run(
        "gh",
        "release",
        "create",
        tag,
        "--verify-tag",
        "--draft",
        "--target",
        commit,
        "--title",
        f"NekoProxy {tag}",
        "--notes-file",
        str(notes),
        *map(str, asset_paths),
    )
    draft = json.loads(
        run("gh", "release", "view", tag, "--json", "databaseId,tagName,isDraft,assets")
    )
    if not draft["isDraft"] or draft["tagName"] != tag:
        raise RuntimeError(f"Expected an uploaded draft Release for {tag}.")
    verify_assets(draft["assets"], expected_assets, tag)
    require_current_ref(ref, pushed_sha, remote_tags(ref))
    latest = "false" if has_newer_release else "true"
    run(
        "gh",
        "api",
        "--method",
        "PATCH",
        f"{endpoint}/{draft['databaseId']}",
        "-F",
        "draft=false",
        "-f",
        f"make_latest={latest}",
    )
    published = json.loads(run("gh", "api", f"{endpoint}/tags/{tag}"))
    if (
        published["id"] != draft["databaseId"]
        or published["draft"]
        or not managed_release(published)
    ):
        raise RuntimeError(f"Could not verify the published Release for {tag}.")
    verify_assets(published["assets"], expected_assets, tag)
    print(published["html_url"], flush=True)

    prune_versions(endpoint, tag, published["id"], pushed_sha, releases(endpoint))


if __name__ == "__main__":
    try:
        if len(sys.argv) < 3:
            raise RuntimeError("Usage: publish-release.py NOTES_FILE ASSET [ASSET ...]")
        notes, *assets = map(Path, sys.argv[1:])
        publish(
            os.environ["GH_REPO"],
            os.environ["RELEASE_TAG"],
            os.environ["RELEASE_EVENT_SHA"],
            notes,
            assets,
        )
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
