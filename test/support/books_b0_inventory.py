#!/usr/bin/env python3
"""Rebuild secret-free Bookshelf B0 artifacts from a private API snapshot.

Expected input layout::

    SNAPSHOT/
      deployment-v1.json
      ebooks/*.json
      audiobooks/*.json
      latency-v1.json

No raw title, author, path, connector, or credential value is written to the repository.
"""

from __future__ import annotations

import argparse
from collections import Counter
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

CAPTURED_AT = "2026-08-20"
INVENTORY_PATH = Path("docs/audits/data/bookshelf-inventory-v1.json")
FIXTURE_PATH = Path("test/support/fixtures/books/bookshelf-api-v1.json")
INSTANCE_NAMES = ("ebooks", "audiobooks")
REQUIRED_ROOT_INPUTS = ("deployment-v1.json", "latency-v1.json")
REQUIRED_INSTANCE_INPUTS = (
    "system-status.json",
    "authors.json",
    "books.json",
    "editions.json",
    "book-files.json",
    "quality-profiles.json",
    "naming.json",
    "media-management.json",
    "download-client-config.json",
    "download-clients.json",
    "indexers.json",
    "root-folders.json",
)


def read(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def encode(value) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n"


def validate_required_inputs(snapshot: Path) -> None:
    required = [snapshot / name for name in REQUIRED_ROOT_INPUTS]
    required.extend(
        snapshot / instance / name
        for instance in INSTANCE_NAMES
        for name in REQUIRED_INSTANCE_INPUTS
    )
    missing = [str(path.relative_to(snapshot)) for path in required if not path.is_file()]
    if missing:
        raise ValueError("missing required snapshot inputs: " + ", ".join(missing))


def private_snapshot_manifest(snapshot: Path) -> dict:
    paths = [snapshot / "deployment-v1.json", snapshot / "latency-v1.json"]
    for instance in ["ebooks", "audiobooks"]:
        paths.extend(sorted((snapshot / instance).glob("*.json")))
    entries = [
        f"{path.relative_to(snapshot)}:{hashlib.sha256(path.read_bytes()).hexdigest()}"
        for path in paths
    ]
    digest = hashlib.sha256(("\n".join(entries) + "\n").encode()).hexdigest()
    return {"file_count": len(entries), "sha256": digest}


def file_formats(files: list[dict]) -> dict[str, int]:
    return dict(
        sorted(
            Counter(
                Path(item["path"]).suffix.lower().lstrip(".")
                for item in files
            ).items()
        )
    )


def inventory(snapshot: Path) -> dict:
    deployment = read(snapshot / "deployment-v1.json")
    if deployment["captured_at"] != CAPTURED_AT:
        raise ValueError("deployment capture date does not match transformer version")
    source = deployment["source"]
    latency = read(snapshot / "latency-v1.json")
    instances = {}
    for name, consumer, root_role in [
        ("ebooks", "booklore", "books"),
        ("audiobooks", "audiobookshelf", "audiobooks"),
    ]:
        directory = snapshot / name
        status = read(directory / "system-status.json")
        if status["branch"] != source["application_branch"] or status["version"] != source["application_version"]:
            raise ValueError(f"{name} system status does not match deployment evidence")
        authors = read(directory / "authors.json")
        books = read(directory / "books.json")
        editions = read(directory / "editions.json")
        files = read(directory / "book-files.json")
        profiles = read(directory / "quality-profiles.json")
        naming = read(directory / "naming.json")
        media = read(directory / "media-management.json")
        downloads = read(directory / "download-client-config.json")
        clients = read(directory / "download-clients.json")
        sources = read(directory / "indexers.json")

        instances[name] = {
            "consumer": consumer,
            "counts": {
                "authors": len(authors),
                "editions": len(editions),
                "files": len(files),
                "works": len(books),
            },
            "download_clients": dict(
                sorted(Counter(client["protocol"] for client in clients).items())
            ),
            "file_formats": file_formats(files),
            "import": {
                "completed_download_handling": downloads[
                    "enableCompletedDownloadHandling"
                ],
                "copy_using_hardlinks": media["copyUsingHardlinks"],
                "minimum_free_space_mb": media["minimumFreeSpaceWhenImporting"],
                "rename_books": naming["renameBooks"],
                "standard_book_format": naming["standardBookFormat"],
            },
            "indexers": dict(
                sorted(Counter(source["protocol"] for source in sources).items())
            ),
            "monitored": {
                "authors": sum(bool(author["monitored"]) for author in authors),
                "editions": sum(bool(edition["monitored"]) for edition in editions),
                "works": sum(bool(book["monitored"]) for book in books),
            },
            "quality_profiles": [profile["name"] for profile in profiles],
            "root_role": root_role,
        }

    return {
        "capture": {
            "api": "/api/v1",
            "generator": "test/support/books_b0_inventory.py",
            "inputs": [
                "deployment-v1.json",
                "latency-v1.json",
                "ebooks/*.json",
                "audiobooks/*.json",
            ],
            "method": "read-only Bookshelf API snapshot; raw responses retained outside source control",
            "private_snapshot_manifest": private_snapshot_manifest(snapshot),
        },
        "captured_at": CAPTURED_AT,
        "instances": instances,
        "latency_ms": {
            "bookshelf_search": {
                **latency["bookshelf_search"]["summary"],
                "method": "10 sequential public-title searches through the active eBook Bookshelf API from inside its LXC; mixed existing cache state",
            },
            "provider_work_lookup": {
                **latency["provider_work"]["summary"],
                "method": "10 sequential accepted public-corpus work lookups from the capture host",
            },
        },
        "privacy": {
            "committed_data": "aggregate counts, policies, and protocol classes only",
            "raw_inventory_committed": False,
            "removed": [
                "API keys",
                "hostnames and addresses",
                "library paths",
                "author and title names",
                "provider IDs tied to the household library",
            ],
        },
        "source": source,
        "version": 1,
    }


def replace_book(book: dict, index: int, author_id: int) -> dict:
    value = deepcopy(book)
    primary_editions = {1: 1, 2: 3, 3: 4}
    file_counts = {1: 2, 2: 1, 3: 1}
    sizes = {1: 3072, 2: 4096, 3: 8192}
    value.update(
        {
            "added": f"2000-01-0{index}T00:00:00Z",
            "authorId": author_id,
            "authorTitle": f"Fixture Author {author_id}",
            "foreignBookId": f"fixture-work-{index:03d}",
            "foreignEditionId": f"fixture-edition-{primary_editions[index]:03d}",
            "genres": ["Fixture"],
            "id": index,
            "images": [],
            "lastSearchTime": None,
            "links": [],
            "pageCount": 100 * index,
            "ratings": {"popularity": index * 10, "value": 4.0, "votes": index * 100},
            "releaseDate": f"200{index}-01-01T00:00:00Z",
            "seriesTitle": "Fixture Series" if index == 2 else "",
            "title": f"Fixture Work {index}",
            "titleSlug": f"fixture-work-{index}",
        }
    )
    value["statistics"] = {
        "bookCount": 1,
        "bookFileCount": file_counts[index],
        "percentOfBooks": 100,
        "sizeOnDisk": sizes[index],
        "totalBookCount": 1,
    }
    return value


def replace_edition(edition: dict, index: int, book_id: int) -> dict:
    value = deepcopy(edition)
    value.update(
        {
            "asin": f"FIXTURE{index:04d}",
            "bookId": book_id,
            "disambiguation": "",
            "foreignEditionId": f"fixture-edition-{index:03d}",
            "id": index,
            "images": [],
            "isbn13": f"9780000000{index:03d}",
            "links": [],
            "manualAdd": False,
            "overview": "Fixture edition used by the B0 API contract.",
            "pageCount": 100 * index,
            "publisher": "Fixture Press",
            "ratings": {"popularity": index * 10, "value": 4.0, "votes": index * 100},
            "releaseDate": f"200{index}-01-01T00:00:00Z",
            "title": f"Fixture Edition {index}",
            "titleSlug": f"fixture-edition-{index}",
        }
    )
    return value


def synthetic_author(source: dict, author_id: int, media_kind: str) -> dict:
    ebook = media_kind == "ebooks"
    value = deepcopy(source)
    value.update(
        {
            "added": f"2000-01-0{author_id}T00:00:00Z",
            "authorMetadataId": 1000 + author_id,
            "authorName": f"Fixture Author {author_id}",
            "authorNameLastFirst": f"Author {author_id}, Fixture",
            "cleanName": f"fixtureauthor{author_id}",
            "foreignAuthorId": f"fixture-author-{author_id:03d}",
            "genres": ["Fixture"],
            "id": author_id,
            "images": [],
            "links": [],
            "monitorNewItems": "all" if ebook else "none",
            "overview": "Fixture author used by the B0 API contract.",
            "path": f"/library/{media_kind}/Fixture Author {author_id}",
            "qualityProfileId": 1 if ebook else 2,
            "ratings": {"popularity": author_id * 10, "value": 4.0, "votes": author_id * 100},
            "rootFolderPath": f"/library/{media_kind}",
            "sortName": f"fixture author {author_id}",
            "sortNameLastFirst": f"author {author_id} fixture",
            "titleSlug": f"fixture-author-{author_id}",
        }
    )
    value["statistics"] = (
        {
            "availableBookCount": 2,
            "bookCount": 2,
            "bookFileCount": 3,
            "percentOfBooks": 100,
            "sizeOnDisk": 7168,
            "totalBookCount": 2,
        }
        if ebook
        else {
            "availableBookCount": 1,
            "bookCount": 1,
            "bookFileCount": 1,
            "percentOfBooks": 100,
            "sizeOnDisk": 8192,
            "totalBookCount": 1,
        }
    )
    return value


def bookshelf_fixture(snapshot: Path) -> dict:
    deployment_source = read(snapshot / "deployment-v1.json")["source"]
    ebooks = snapshot / "ebooks"
    audio = snapshot / "audiobooks"
    raw_authors = read(ebooks / "authors.json")
    raw_books = read(ebooks / "books.json")
    raw_editions = read(ebooks / "editions.json")
    raw_files = read(ebooks / "book-files.json") + read(audio / "book-files.json")

    authors = [
        synthetic_author(raw_authors[0], 1, "ebooks"),
        synthetic_author(raw_authors[0], 2, "audiobooks"),
    ]

    book_candidates = [
        next(book for book in raw_books if not book.get("seriesTitle")),
        next(book for book in raw_books if book.get("seriesTitle")),
        next(
            book
            for book in raw_books
            if book.get("statistics", {}).get("bookFileCount", 0) > 1
        ),
    ]
    books = [
        replace_book(book, index, [1, 1, 2][index - 1])
        for index, book in enumerate(book_candidates, 1)
    ]

    edition_candidates = [
        next(edition for edition in raw_editions if edition.get("format") == format_name)
        for format_name in ["ebook", "Hardcover", "Kindle Edition", "Audible Audio"]
    ]
    edition_book_ids = [1, 1, 2, 3]
    editions = [
        replace_edition(edition, index, edition_book_ids[index - 1])
        for index, edition in enumerate(edition_candidates, 1)
    ]

    files = []
    file_book_ids = [1, 1, 2, 3]
    file_author_ids = [1, 1, 1, 2]
    file_sizes = [1024, 2048, 4096, 8192]
    for index, extension in enumerate([".epub", ".azw3", ".mobi", ".m4b"], 1):
        item = deepcopy(
            next(
                source
                for source in raw_files
                if Path(source["path"]).suffix.lower() == extension
            )
        )
        book_id = file_book_ids[index - 1]
        author_id = file_author_ids[index - 1]
        quality_name = extension.lstrip(".").upper()
        item.update(
            {
                "authorId": author_id,
                "bookId": book_id,
                "dateAdded": f"2000-02-0{index}T00:00:00Z",
                "id": index,
                "path": f"/library/{'audiobooks' if extension == '.m4b' else 'ebooks'}/Fixture Author {author_id}/Fixture Work {book_id}{extension}",
                "quality": {
                    "quality": {"id": index, "name": quality_name},
                    "revision": {"isRepack": False, "real": 0, "version": 1},
                },
                "qualityWeight": index * 10,
                "size": file_sizes[index - 1],
            }
        )
        if extension == ".m4b":
            item["mediaInfo"] = {
                "audioBitRate": "128 kbps",
                "audioBits": "",
                "audioChannels": 2,
                "audioCodec": "AAC",
                "audioSampleRate": "44.1kHz",
            }
        files.append(item)

    profiles = []
    for index, (directory, profile_name) in enumerate(
        [(ebooks, "eBook"), (audio, "Spoken")], 1
    ):
        profile = deepcopy(
            next(
                item
                for item in read(directory / "quality-profiles.json")
                if item["name"] == profile_name
            )
        )
        profile["id"] = index
        profiles.append(profile)

    roots = []
    for index, (directory, path) in enumerate(
        [(ebooks, "/library/ebooks"), (audio, "/library/audiobooks")], 1
    ):
        root = deepcopy(read(directory / "root-folders.json")[0])
        root.update(
            {
                "accessible": True,
                "freeSpace": 1_000_000_000,
                "id": index,
                "path": path,
                "totalSpace": 2_000_000_000,
            }
        )
        roots.append(root)

    return {
        "captured_at": CAPTURED_AT,
        "responses": {
            "author": authors,
            "book": books,
            "bookfile": files,
            "config/mediamanagement": read(ebooks / "media-management.json"),
            "config/naming": read(ebooks / "naming.json"),
            "edition": editions,
            "qualityprofile": profiles,
            "rootfolder": roots,
            "system/status": {
                key: read(ebooks / "system-status.json")[key]
                for key in ["appName", "branch", "isDocker", "isLinux", "version"]
            },
        },
        "sanitization": {
            "derived_from_live_api": True,
            "preserved": [
                "response keys and value types",
                "boolean and enum semantics",
                "quality/profile names",
                "naming and media-management policy",
            ],
            "remapped": [
                "all IDs and bibliographic identifiers",
                "authors, titles, genres, descriptions, and images",
                "paths and root folders",
                "all activity and release timestamps",
                "file sizes and aggregate sizes",
                "ratings, popularity, votes, page counts, and statistics",
                "audio measurements",
            ],
            "removed": ["credentials", "connector fields", "personal paths"],
        },
        "source": {
            "application": deployment_source["application"],
            "image_revision": deployment_source["image_revision"],
            "version": deployment_source["application_version"],
        },
        "version": 1,
    }


def render_and_validate_artifacts(snapshot: Path) -> dict[Path, str]:
    artifacts = {
        INVENTORY_PATH: inventory(snapshot),
        FIXTURE_PATH: bookshelf_fixture(snapshot),
    }
    rendered = {relative: encode(value) for relative, value in artifacts.items()}

    for relative, content in rendered.items():
        if json.loads(content) != artifacts[relative]:
            raise ValueError(f"rendered artifact failed validation: {relative}")

    return rendered


def write_artifacts(output_root: Path, artifacts: dict[Path, str]) -> None:
    temporary_paths = {}

    try:
        for relative, content in artifacts.items():
            target = output_root / relative
            target.parent.mkdir(parents=True, exist_ok=True)

            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=target.parent,
                prefix=f".{target.name}.",
                delete=False,
            ) as temporary:
                temporary_path = Path(temporary.name)
                temporary_paths[target] = temporary_path
                temporary.write(content)
                temporary.flush()
                os.fsync(temporary.fileno())
    except Exception:
        for temporary_path in temporary_paths.values():
            temporary_path.unlink(missing_ok=True)
        raise

    try:
        for target, temporary_path in temporary_paths.items():
            os.replace(temporary_path, target)
    finally:
        for temporary_path in temporary_paths.values():
            temporary_path.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--snapshot-dir", required=True, type=Path)
    parser.add_argument("--output-root", default=Path.cwd(), type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    validate_required_inputs(args.snapshot_dir)
    artifacts = render_and_validate_artifacts(args.snapshot_dir)
    mismatches = []
    for relative, content in artifacts.items():
        target = args.output_root / relative
        if args.check:
            if not target.is_file() or target.read_text(encoding="utf-8") != content:
                mismatches.append(str(relative))

    if mismatches:
        print("B0 artifact mismatch: " + ", ".join(mismatches), file=sys.stderr)
        raise SystemExit(1)

    if not args.check:
        write_artifacts(args.output_root, artifacts)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"B0 inventory error: {error}", file=sys.stderr)
        raise SystemExit(1) from None
