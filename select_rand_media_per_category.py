# Truncates output file, calls function twice with different pattern and source folder. Appends twice to output file!
# Builds 2d_media_paths.txt once, pauses briefly so double-click users can read output, then exits.
# CLI: --no-pause (exit immediately), --pause N (seconds before exit, default 5). Writes beside this script.

import glob
import os
import random
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_FILENAME = '2d_media_paths.txt'
DEFAULT_PAUSE_SEC = 5

RUN1_SOURCE_DIRECTORIES = [
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media',
    r'P:\p_cld_media\pcld_combo_media_dlna\mrsk_media\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\misc\non_bg\non_bg_short\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\pk_media\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\ali_pentecost\bg\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\ali_pentecost\ap_short\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\aline_barreto\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\amanda_trivizas\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\amanda_trivizas\non_bg\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\shantal_monique\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\ana_cheri\ac_short\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\antje' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\arianny_celeste\arc_short' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\brianna_dale\bg' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\chromita\latest' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\courtney_tailor' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\demi_rose_mawby' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\georgina_gentle' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\misc\llrd' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\misc\of_misc_short' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\misc_prem\misc_prem_short' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\jadelyn_music\latest\jm_short' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\keisha_grey\keisha_grey_cps' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\kinsey_wolanski' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\light_skin_lanii\lsl_short' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\maria_dmar' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\marie_madore' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\shantal_monique' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\stef_gurzanski_knight\bg\sgk_bg_short' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\stef_gurzanski_knight\sgk_nbg_short' + r'\concat',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\steffy_moreno' + r'\concat',
]
RUN1_FILE_PATTERNS = [r'**\*_rand_combo.m*']

RUN2_SOURCE_DIRECTORIES = [
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\mia_monroe',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\misc',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\misc\cps',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\misc\ln_mix',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\misc\favs',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\misc\non_bg',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\nicole_aniston',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\peachy_skye',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\poonam_pandey',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\sadie_summers',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\stef_gurzanski_knight\bg',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\summer_brookes',
    r'P:\p_cld_media\pcld_combo_media_dlna\of_media\tru_kait',
    r'P:\p_cld_media\pcld_combo_media_dlna\vxn_media',
    r'E:\e1_media\e_local_media\ph_media_1\cl',
    r'E:\e1_media\e_local_media\ptfr_media_1',
    r'E:\e1_media\e_local_media\ptfr_media_1\c4s',
    r'E:\e1_media\e_local_media\sxmx_media_1',
    r'E:\e1_media\e_local_media\sxmx_media_1\kourtney_love',
    r'F:\f1_media\f_local_media\ll_media_1\c4s',
    r'F:\f1_media\f_local_media\ll_media_1\Nikki Brooks',
    r'F:\f1_media\f_local_media\nam_media_1\2D\nam_cache',
    r'E:\e1_media\e_local_media\rk_media_1',
    r'E:\e1_media\e_local_media\pf_media_1\fk',
    r'E:\e1_media\e_local_media\pf_media_1\pf_1',
    r'E:\e1_media\e_local_media\pf_media_1\pf_2',
    r'E:\e1_media\e_local_media\pf_media_1\pf_3',
    r'E:\e1_media\e_local_media\pf_media_1\tmw_media',
    r'E:\e1_media\e_local_media\ns_media_1',
    r'E:\e1_media\e_local_media\js_media_1',
    r'E:\e1_media\e_local_media\ft_media_1\mv',
    r'E:\e1_media\e_local_media\ft_media_1\mv_2',
    r'E:\e1_media\e_local_media\fh_media_1\fh_cache',
    r'E:\e1_media\e_local_media\brz_media_1',
    r'E:\e1_media\e_local_media\bbf_media_1',
    r'F:\f1_media\f_local_media\wca_media_1',
    r'F:\f1_media\f_local_media\us_media_1',
    r'F:\f1_media\f_local_media\tf_media_1',
    r'F:\f1_media\f_local_media\scvp_media_1',
    r'F:\f1_media\f_local_media\scvp_media_1\fph',
    r'F:\f1_media\f_local_media\np_media_1\bm',
    r'F:\f1_media\f_local_media\np_media_1\bs',
    r'F:\f1_media\f_local_media\np_media_1\ml\mwb',
    r'F:\f1_media\f_local_media\np_media_1\ml\mwcp',
    r'F:\f1_media\f_local_media\np_media_1\mts',
    r'F:\f1_media\f_local_media\np_media_1\ssc',
    r'F:\f1_media\f_local_media\np_media_1\nfb',
    r'F:\f1_media\f_local_media\nmwg_media_1',
    r'F:\f1_media\f_local_media\mw_media_1',
    r'F:\f1_media\f_local_media\misc_media_1',
    r'F:\f1_media\f_local_media\bng_media_1',
    r'F:\f1_media\f_local_media\bng_media_1\older',
    r'F:\f1_media\f_local_media\bb_media_1\bb_cache',
    r'D:\d1_media\d_local_media\jwt_media_1\c4s',
    r'D:\d1_media\d_local_media\jwt_media_1',
    r'D:\d1_media\d_local_media\ts_media_1\fs',
    r'D:\d1_media\d_local_media\ts_media_1\mf',
    r'D:\d1_media\d_local_media\ts_media_1\pm',
    r'D:\d1_media\d_local_media\ts_media_1\slm',
    r'D:\d1_media\d_local_media\ts_media_1\splr',
    r'D:\d1_media\d_local_media\ts_media_1\tp',
    r'D:\d1_media\d_local_media\ts_media_1\ts',
    r'F:\f1_media\f_local_media\misc_media_1\astr',
    r'F:\f1_media\f_local_media\misc_media_1\hhfy',
    r'F:\f1_media\f_local_media\misc_media_1\af',
    r'F:\f1_media\f_local_media\misc_media_1\mfs',
    r'F:\f1_media\f_local_media\misc_media_1\c4s',
    r'F:\f1_media\f_local_media\misc_media_1\dnre',
    r'F:\f1_media\f_local_media\misc_media_1\hm',
    r'F:\f1_media\f_local_media\misc_media_1\maxl',
    r'F:\f1_media\f_local_media\misc_media_1\mmr',
    r'F:\f1_media\f_local_media\misc_media_1\prg',
    r'F:\f1_media\f_local_media\misc_media_1\swtm',
    r'F:\f1_media\f_local_media\misc_media_1\xb',
    r'F:\f1_media\f_local_media\misc_media_1\zw',
    r'F:\f1_media\f_local_media\misc_media_1',
]
RUN2_FILE_PATTERNS = ['*.mp4', '*.wmv']


def find_random_files_per_directory(
    source_dirs: List[str],
    patterns: List[str],
    output_file: Optional[str] = None,
) -> Dict[str, Optional[str]]:
    found_files: Dict[str, Optional[str]] = {}

    for directory in source_dirs:
        all_files_in_dir: List[str] = []
        for pattern in patterns:
            search_pattern = str(Path(directory) / pattern)
            all_files_in_dir.extend(glob.glob(search_pattern, recursive=True))

        if all_files_in_dir:
            found_files[directory] = random.choice(all_files_in_dir)
        else:
            found_files[directory] = None

    if output_file:
        with open(output_file, 'a', encoding='utf-8') as f:
            for _directory, file_path in found_files.items():
                if file_path:
                    f.write(f'{file_path}\n')

    return found_files


def output_path() -> Path:
    return SCRIPT_DIR / OUTPUT_FILENAME


def relaunch_with_console_if_needed() -> None:
    """Windows .py double-click often uses pythonw.exe (no window). Re-open with python.exe."""
    if Path(sys.executable).name.lower() != 'pythonw.exe':
        return
    script = Path(__file__).resolve()
    py_exe = Path(sys.executable).with_name('python.exe')
    if not py_exe.is_file():
        py_exe = Path('python')
    cmd = [str(py_exe), str(script), *sys.argv[1:]]
    flags = getattr(subprocess, 'CREATE_NEW_CONSOLE', 0)
    subprocess.Popen(cmd, cwd=str(script.parent), creationflags=flags)
    raise SystemExit(0)


def build_2d_media_paths() -> int:
    out = output_path()
    with open(out, 'w', encoding='utf-8') as f:
        pass

    print('Run 1: rand_combo patterns...')
    run1 = find_random_files_per_directory(
        RUN1_SOURCE_DIRECTORIES, RUN1_FILE_PATTERNS, output_file=str(out)
    )
    _print_run_summary('Run 1', run1)

    print('Run 2: mp4/wmv patterns...')
    run2 = find_random_files_per_directory(
        RUN2_SOURCE_DIRECTORIES, RUN2_FILE_PATTERNS, output_file=str(out)
    )
    _print_run_summary('Run 2', run2)

    with open(out, encoding='utf-8') as f:
        line_count = sum(1 for line in f if line.strip())
    print(f'Wrote {line_count} path(s) to {out}')
    return line_count


def _print_run_summary(label: str, found: Dict[str, Optional[str]]) -> None:
    print(f'{label} sample (dir -> file):')
    shown = 0
    for directory, file_path in found.items():
        print(f'  {directory}: {file_path}')
        shown += 1
        if shown >= 5:
            remaining = len(found) - shown
            if remaining > 0:
                print(f'  ... and {remaining} more director{"y" if remaining == 1 else "ies"}')
            break


def parse_pause_seconds(argv: List[str]) -> int:
    if '--no-pause' in argv or '--once' in argv:
        return 0
    for i, arg in enumerate(argv):
        lower = arg.lower()
        if lower == '--pause' and i + 1 < len(argv):
            try:
                return max(0, int(argv[i + 1]))
            except ValueError:
                pass
        if lower.startswith('--pause='):
            try:
                return max(0, int(lower.split('=', 1)[1]))
            except ValueError:
                pass
    return DEFAULT_PAUSE_SEC


def main(argv: Optional[List[str]] = None) -> int:
    os.chdir(SCRIPT_DIR)
    relaunch_with_console_if_needed()

    raw_argv = list(sys.argv[1:] if argv is None else argv)
    pause_sec = parse_pause_seconds([a.lower() for a in raw_argv])
    exit_code = 0

    try:
        print(f'Working folder: {SCRIPT_DIR}')
        print(f'Output: {output_path()}')
        build_2d_media_paths()
    except Exception as exc:
        exit_code = 1
        print(f'ERROR: {exc}', file=sys.stderr)
        import traceback
        traceback.print_exc()
    finally:
        if pause_sec > 0:
            print(f'Exiting in {pause_sec}s...')
            time.sleep(pause_sec)

    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
