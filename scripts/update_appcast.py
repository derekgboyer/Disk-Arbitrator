#!/usr/bin/env python3
"""Insert one Sparkle release into an appcast, keeping older items."""

import argparse
import email.utils
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"

ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)


def sparkle(name):
    return f"{{{SPARKLE}}}{name}"


def item_version(item):
    node = item.find(sparkle("version"))
    return (node.text or "").strip() if node is not None else ""


def new_tree(link):
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Disk Arbitrator"
    ET.SubElement(channel, "link").text = link or "https://github.com"
    ET.SubElement(channel, "description").text = "Disk Arbitrator updates"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def channel_of(tree):
    channel = tree.getroot().find("channel")
    if channel is None:
        raise SystemExit("appcast has no channel")
    return channel


def load(path):
    return ET.parse(path)


def make_item(args):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.title or f"Version {args.short_version}"
    published = datetime.now(timezone.utc)
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(published)
    ET.SubElement(item, sparkle("version")).text = args.version
    ET.SubElement(item, sparkle("shortVersionString")).text = args.short_version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system_version
    attributes = {
        "url": args.url,
        "length": str(args.length),
        "type": "application/octet-stream",
    }
    if args.ed_signature:
        attributes[sparkle("edSignature")] = args.ed_signature
    ET.SubElement(item, "enclosure", attributes)
    return item


def preserve(channel, previous_path):
    if not previous_path:
        return
    path = Path(previous_path)
    if not path.is_file():
        return
    previous = channel_of(load(path))
    present = {item_version(item) for item in channel.findall("item")}
    for item in previous.findall("item"):
        version = item_version(item)
        if version and version not in present:
            channel.append(item)
            present.add(version)


def write(tree, path):
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--preserve-from", default="")
    parser.add_argument("--version", default="")
    parser.add_argument("--short-version", default="")
    parser.add_argument("--url", default="")
    parser.add_argument("--length", default="")
    parser.add_argument("--ed-signature", default="")
    parser.add_argument("--minimum-system-version", default="13.0")
    parser.add_argument("--title", default="")
    parser.add_argument("--link", default="", help="Channel link for a newly created appcast. The release workflow passes https://github.com/<owner>/<repo>.")
    args = parser.parse_args()

    destination = Path(args.appcast)
    tree = load(destination) if destination.is_file() else new_tree(args.link)
    channel = channel_of(tree)

    if args.version:
        if not args.short_version or not args.url or not args.length:
            raise SystemExit("--version requires --short-version, --url, and --length")
        for item in list(channel.findall("item")):
            if item_version(item) == args.version:
                channel.remove(item)
        # Newest release stays first.
        insert_at = None
        for index, child in enumerate(list(channel)):
            if child.tag == "item":
                insert_at = index
                break
        item = make_item(args)
        if insert_at is None:
            channel.append(item)
        else:
            channel.insert(insert_at, item)

    preserve(channel, args.preserve_from)
    destination.parent.mkdir(parents=True, exist_ok=True)
    write(tree, destination)


if __name__ == "__main__":
    main()
