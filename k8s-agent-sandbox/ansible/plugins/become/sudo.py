# -*- coding: utf-8 -*-
from __future__ import annotations

DOCUMENTATION = """
    name: sudo
    short_description: Substitute User DO with sudo-rs and wrapped PAM prompt compatibility
    description:
        - This become plugin allows executing commands as another user via sudo,
          with extended prompt regex support for modern distributions using sudo-rs.
    author: ansible (@core)
    options:
        become_user:
            description: User you 'become' to execute the task
            default: root
            ini:
              - section: privilege_escalation
                key: become_user
              - section: sudo_become_plugin
                key: user
            vars:
              - name: ansible_become_user
              - name: ansible_sudo_user
            env:
              - name: ANSIBLE_BECOME_USER
              - name: ANSIBLE_SUDO_USER
        become_exe:
            description: Sudo executable
            default: sudo
            ini:
              - section: privilege_escalation
                key: become_exe
              - section: sudo_become_plugin
                key: executable
            vars:
              - name: ansible_become_exe
              - name: ansible_sudo_exe
            env:
              - name: ANSIBLE_BECOME_EXE
              - name: ANSIBLE_SUDO_EXE
        become_flags:
            description: Options to pass to sudo
            default: -H -S -n
            ini:
              - section: privilege_escalation
                key: become_flags
              - section: sudo_become_plugin
                key: flags
            vars:
              - name: ansible_become_flags
              - name: ansible_sudo_flags
            env:
              - name: ANSIBLE_BECOME_FLAGS
              - name: ANSIBLE_SUDO_FLAGS
        become_pass:
            description: Password to pass to sudo
            required: False
            vars:
              - name: ansible_become_password
              - name: ansible_become_pass
              - name: ansible_sudo_pass
            env:
              - name: ANSIBLE_BECOME_PASS
              - name: ANSIBLE_SUDO_PASS
            ini:
              - section: sudo_become_plugin
                key: password
"""

import re
import shlex
from ansible.plugins.become import BecomeBase


class BecomeModule(BecomeBase):

    name = "sudo"

    fail = ("Sorry, try again.",)
    missing = (
        "Sorry, a password is required to run sudo",
        "sudo: a password is required",
    )

    def check_password_prompt(self, b_output: bytes) -> bool:
        # Check standard GNU sudo prompt
        matched = super().check_password_prompt(b_output)
        if not matched and getattr(self, "prompt", None):
            # Compatibility with Ubuntu / Debian sudo-rs and wrapped PAM prompts:
            # Matches '[sudo: [sudo via ansible, key=...] password:] Password:'
            sudo_rs = re.compile(
                rf"\[sudo:\s+{re.escape(self.prompt)}\]\s+\S.+\Z".encode()
            )
            matched = any(sudo_rs.match(line) for line in b_output.splitlines())
        return matched

    def build_become_command(self, cmd, shell):
        super().build_become_command(cmd, shell)

        if not cmd:
            return cmd

        becomecmd = self.get_option("become_exe") or self.name
        flags = self.get_option("become_flags") or ""
        prompt = ""
        if self.get_option("become_pass"):
            self.prompt = "[sudo via ansible, key=%s] password:" % self._id
            if flags:
                reflag = []
                for flag in shlex.split(flags):
                    if flag in ("-n", "--non-interactive"):
                        continue
                    elif not flag.startswith("--"):
                        flag = re.sub(r"^(-\w*)n(\w*.*)", r"\1\2", flag)
                    reflag.append(flag)
                flags = shlex.join(reflag)

            prompt = '-p "%s"' % (self.prompt)

        user = self.get_option("become_user") or ""
        if user:
            user = "-u %s" % (user)

        return " ".join(
            [
                becomecmd,
                flags,
                prompt,
                user,
                self._build_success_command(cmd, shell),
            ]
        )

