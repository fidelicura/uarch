#!/usr/bin/env python3


"""
Invoke `--help` for information about this script.
"""


import argparse
import json
import os
import shlex
import shutil
import subprocess

from pathlib import Path


COLOR_RED = "\033[31m"
COLOR_RESET = "\033[0m"


class Arguments:
    parser: argparse.ArgumentParser
    namespace: argparse.Namespace

    def __init__(self) -> None:
        self.parser = argparse.ArgumentParser(
            usage="cage.py [options] --core-id <ID> <PATH>",
            description=(
                "Run a binary under a deterministic execution cage:\n"
                "pin to a core, disable ASLR/SMT/NMI watchdog, lock\n"
                "CPU frequency and C-state, and isolate from kernel\n"
                "interruptions. MOST ACTIONS REQUIRE ROOT (SUDO)!"
            ),
            formatter_class=argparse.RawTextHelpFormatter,
        )

        self.parser.add_argument(
            "path",
            help="path to the binary to execute inside the cage",
            metavar="<PATH>",
            type=self._resolve_binary,
        )
        self.parser.add_argument(
            "forwarded",
            help="arguments forwarded to <PATH> (use -- to separate flags)",
            metavar="<ARGS>",
            nargs=argparse.REMAINDER,
        )

        self.parser.add_argument(
            "--core-id",
            action="store",
            help="pin process to physical core ID at creation",
            required=True,
            type=int,
        )
        self.parser.add_argument(
            "--enable-aslr",
            action="store_true",
            help="[sudo] re-enable ASLR (reduces determinism)\n"
                 f"{COLOR_RED}(requires `sysctl` in $PATH){COLOR_RESET}",
        )
        self.parser.add_argument(
            "--enable-nmi",
            action="store_true",
            help="[sudo] re-enable NMI watchdog (adds kernel interrupts)\n"
                 f"{COLOR_RED}(requires `sysctl` in $PATH){COLOR_RESET}",
        )
        self.parser.add_argument(
            "--enable-smt",
            action="store_true",
            help="[sudo] re-enable CPU SMT (shares core resources)",
        )
        self.parser.add_argument(
            "--no-isol-proc",
            action="store_true",
            help="[sudo] disable process isolation from kernel interruptions\n"
                 f"{COLOR_RED}(requires `chrt` in $PATH){COLOR_RESET}",
        )
        self.parser.add_argument(
            "--no-lock-cstate",
            action="store_true",
            help="[sudo] do not lock CPU C-state\n"
                 f"{COLOR_RED}(requires `cpupower` in $PATH{COLOR_RESET})",
        )
        self.parser.add_argument(
            "--no-lock-freq",
            action="store_true",
            help="[sudo] do not lock CPU frequency in performance mode\n"
                 f"{COLOR_RED}(requires `cpupower` in $PATH{COLOR_RESET})",
        )
        self.parser.add_argument(
            "--record-flamegraph",
            action="store_true",
            help=(
                "[sudo] record perf samples and post-process into `flame.svg`\n"
                f"{COLOR_RED}(requires `perf`, `stackcollapse-perf.pl`, `flamegraph.pl` in $PATH){COLOR_RESET}"
            ),
        )

        self.parser.add_argument(
            "--dry-run",
            action="store_true",
            help="print commands that would be executed, then exit",
        )

    def parse(self) -> argparse.Namespace:
        return self.parser.parse_args()

    @staticmethod
    def _resolve_binary(raw: str) -> Path:
        candidate = Path(raw)
        if candidate.exists():
            return candidate.resolve()

        found = shutil.which(raw)
        if found:
            return Path(found)

        raise argparse.ArgumentTypeError(f"binary not found: {raw}")


class Applier:
    arguments: argparse.Namespace

    def __init__(self, arguments: Arguments) -> None:
        self.arguments = arguments.parse()

        if self.arguments.dry_run:
            for key, value in vars(self.arguments).items():
                print(f"Argument: {key} = {value}")

    @staticmethod
    def _sysctl_read(key: str) -> str:
        return subprocess.check_output(["sysctl", "-n", key]).decode().strip()

    @staticmethod
    def _read_file(path: str) -> str:
        return Path(path).read_text().strip()

    def _snapshot_undo(self) -> list[list[str]]:
        undo: list[list[str]] = []

        if not self.arguments.enable_aslr:
            value = self._sysctl_read("kernel.randomize_va_space")
            undo.append(["sudo", "sysctl", "-w", f"kernel.randomize_va_space={value}"])
        if not self.arguments.enable_nmi:
            value = self._sysctl_read("kernel.nmi_watchdog")
            undo.append(["sudo", "sysctl", "-w", f"kernel.nmi_watchdog={value}"])
        if not self.arguments.enable_smt:
            value = self._read_file("/sys/devices/system/cpu/smt/control")
            undo.append(
                [
                    "sudo",
                    "sh",
                    "-c",
                    f"echo {value} > /sys/devices/system/cpu/smt/control",
                ]
            )
        if not self.arguments.no_lock_freq:
            gov = self._read_file(
                f"/sys/devices/system/cpu/cpu{self.arguments.core_id}"
                "/cpufreq/scaling_governor"
            )
            undo.append(["sudo", "cpupower", "frequency-set", "-g", gov])
        if not self.arguments.no_lock_cstate:
            undo.append(["sudo", "cpupower", "idle-set", "-E"])
        if self.arguments.record_flamegraph:
            value = self._sysctl_read("kernel.perf_event_paranoid")
            undo.append(["sudo", "sysctl", "-w", f"kernel.perf_event_paranoid={value}"])

        if self.arguments.dry_run:
            for command in undo:
                print(f"Teardown: {shlex.join(command)}")

        return undo

    def _snapshot_todo(self) -> tuple[list[list[str]], list[str]]:
        setup: list[list[str]] = []

        if not self.arguments.enable_aslr:
            setup.append(["sudo", "sysctl", "-w", "kernel.randomize_va_space=0"])
        if not self.arguments.enable_nmi:
            setup.append(["sudo", "sysctl", "-w", "kernel.nmi_watchdog=0"])
        if not self.arguments.enable_smt:
            setup.append(["sudo", "sh", "-c", "echo off > /sys/devices/system/cpu/smt/control"])
        if not self.arguments.no_lock_freq:
            setup.append(["sudo", "cpupower", "frequency-set", "-g", "performance"])
        if not self.arguments.no_lock_cstate:
            setup.append(["sudo", "cpupower", "idle-set", "-D", "0"])
        if self.arguments.record_flamegraph:
            setup.append(["sudo", "sysctl", "-w", "kernel.perf_event_paranoid=-1"])

        run: list[str] = []
        if not self.arguments.no_isol_proc:
            run += ["sudo", "chrt", "-f", "99"]
        run += ["taskset", "-c", f"{self.arguments.core_id}"]
        if self.arguments.record_flamegraph:
            run += [
                "perf", "record",
                "-F", "999",
                "-g", "--call-graph", "dwarf",
                "-o", "perf.data",
                "--",
            ]
        run += [f"{self.arguments.path}", *self.arguments.forwarded]

        if self.arguments.dry_run:
            for command in setup:
                print(f"Setup:    {shlex.join(command)}")
            print(f"Run:      {shlex.join(run)}")

        return setup, run

    def _build_flamegraph(self) -> None:
        data = Path("perf.data")
        if not data.exists():
            print("Flamegraph skipped: perf.data missing")
            return

        subprocess.run(
            ["sudo", "chown", f"{os.getuid()}:{os.getgid()}", f"{data}"],
            check=True,
            stdout=subprocess.DEVNULL,
        )

        svg = Path("flame.svg")
        with open(svg, "w") as out:
            script = subprocess.Popen(
                ["perf", "script", "-i", f"{data}"],
                stdout=subprocess.PIPE,
            )
            collapse = subprocess.Popen(
                ["stackcollapse-perf.pl"],
                stdin=script.stdout,
                stdout=subprocess.PIPE,
            )
            assert script.stdout is not None
            script.stdout.close()
            subprocess.run(
                ["flamegraph.pl"],
                stdin=collapse.stdout,
                stdout=out,
                check=True,
            )
            assert collapse.stdout is not None
            collapse.stdout.close()
            script.wait()
            collapse.wait()

        print(f"Flamegraph: {svg.resolve()}")

    def apply(self) -> None:
        todo, run = self._snapshot_todo()
        undo = self._snapshot_undo()

        if self.arguments.dry_run:
            return

        applied: list[list[str]] = []
        try:
            for command_todo, command_undo in zip(todo, undo):
                subprocess.run(command_todo, check=True, stdout=subprocess.DEVNULL)
                applied.append(command_undo)
            subprocess.run(run, check=False)
            if self.arguments.record_flamegraph:
                self._build_flamegraph()
        finally:
            for command in reversed(applied):
                try:
                    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
                except subprocess.CalledProcessError as error:
                    print(f"Teardown failed: {shlex.join(command)}: {error}")


def main() -> None:
    arguments = Arguments()
    Applier(arguments).apply()


if __name__ == "__main__":
    main()
