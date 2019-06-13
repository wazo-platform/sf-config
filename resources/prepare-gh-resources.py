#!/usr/bin/env python3
# -*- encoding: utf-8 -*-

import argparse
import getpass
import os
import sys
from urllib import parse

import github

HEADER = """---
# This file contains the default users group authorized to
# manage Software Factory services configurations.
#
# Adds trusted operator email to the config-core or config-ptl list.
#
resources:
  groups:
    config-ptl:
      description: Team lead for the config repo
      members:
        - admin@zuul.wazo.community
    config-core:
      description: Team core for the config repo
      members: []
  projects:
    wazo-platform:
      description: "Wazo Platform"
      connection: github.com
      source-repositories:
"""

ZUUL_PROJECTS = ["wazo-pbx/sf-config", "wazo-pbx/sf-jobs"]


def main():
    user = None
    password = None

    git_creds_path = os.path.expanduser("~/.git-credentials")
    if os.path.exists(git_creds_path):
        with open(os.path.expanduser("~/.git-credentials")) as f:
            for line in f.readlines():
                url = parse.urlparse(line.strip())
                if url.hostname == "github.com":
                    user = url.username
                    password = url.password

    if not (user and password):
        user = getpass.getpass("User: ")
        password = getpass.getpass("Password: ")

    parser = argparse.ArgumentParser(
        description='Configure Wazo Github project'
    )
    parser.add_argument("--doit", action="store_true")

    args = parser.parse_args()

    f = open("resources.yaml", "w")
    f.write(HEADER)

    g = github.Github(user, password)
    org = g.get_organization("wazo-pbx")
    for repo in org.get_repos():
        print("Doing %s" % repo.full_name)
        if repo.full_name in ZUUL_PROJECTS:
            zuul_configured = True
        else:
            try:
                repo.get_contents("zuul.yaml")
            except github.UnknownObjectException:
                zuul_configured = False
            else:
                zuul_configured = True

        if args.doit and zuul_configured:
            branch = repo.get_branch("master")
            branch.edit_protection(strict=True, contexts=["local/check"])
            try:
                label = repo.get_label("mergeit")
            except github.UnknownObjectException:
                repo.create_label("mergeit", "00FF7F")
            else:
                label.edit("mergeit", "00FF7F")

        if repo.full_name not in ZUUL_PROJECTS:
            if zuul_configured:
                f.write("        - %s:\n" % repo.full_name)
                f.write("            zuul/exclude-unprotected-branches: true\n")
            else:
                f.write("        - %s\n" % repo.full_name)

    f.close()


if __name__ == '__main__':
    sys.exit(main())
