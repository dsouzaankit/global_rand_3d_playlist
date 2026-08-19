import os
import time
import shutil
import math
from pathlib import Path
from pprint import pprint


def move_media_files_recursive(source_dir, dest_dir):
    """
    Moves media (avs) files from a source folder to a destination folder.

    Args:
        source_dir (str): The path to the source directory.
        dest_dir (str): The path to the destination directory.
    """

    source_path = Path(source_dir)
    dest_path = Path(dest_dir)

    # Create the destination directory if it doesn't exist
    dest_path.mkdir(parents=True, exist_ok=True)

    # Use rglob to find all .avs files recursively
    for file_path in source_path.rglob("*.avs"):
        # Define the destination path for the file
        destination_file_path = dest_path / file_path.name
        
        try:
            # Move the file
            shutil.move(file_path, destination_file_path)
            print(f"Moved: {file_path} -> {destination_file_path}")
        except shutil.Error as e:
            # Handle potential errors, e.g., file already exists at destination
            print(f"Error moving {file_path}: {e}")
        except Exception as e:
            # Handle other unexpected errors
            print(f"An unexpected error occurred with file {file_path}: {e}")

# Define your source and destination folder paths
source_directory = 'C:\\ProgramData\\StreamTo3D'
destination_directory = '.\\avs'

move_media_files_recursive(source_directory, destination_directory)


pref_substr = 'rand_combo.m'
pref_substr_max_cnt = 30
pref_substr_ctr = 0
oldest_pref_substr_ts = math.inf
oldest_pref_substr_idx = -1
sort_tuples = []

"""
Prioritizes newer rand_combo files till they hit max. count = pref_substr_max_cnt
Non-rand_combo files + older rand_combo in surplus of count = pref_substr_max_cnt are sorted by recent timestamp
"""
# Define the custom key function
def sort_key(file_index, filename, folder_path):
    global pref_substr_ctr
    global oldest_pref_substr_ts
    global oldest_pref_substr_idx
    global sort_tuples
    # print(pref_substr_ctr)
    # print(file_index)
    # print(filename)
    # Priority check: False comes before True
    is_not_priority = pref_substr not in filename
    # Secondary sort key: The timestamp itself
    file_ts = -1.00 * os.path.getmtime(os.path.join(folder_path, filename))
    if not is_not_priority:
        if file_ts * -1.00 < oldest_pref_substr_ts:
            oldest_pref_substr_idx = file_index
            oldest_pref_substr_ts = file_ts * -1.00
        pref_substr_ctr += 1
        # print(oldest_pref_substr_idx)
        # print(len(sort_tuples))
        if pref_substr_ctr > pref_substr_max_cnt:
            sort_tuples[oldest_pref_substr_idx] = (True, oldest_pref_substr_ts)
            pref_substr_ctr -= 1
    final_priority = (is_not_priority, file_ts)
    # print(final_priority)
    sort_tuples.append(final_priority)
    return final_priority

def create_m3u_playlist(folder_path, output_filename=".\\playlist.m3u"):
    """
    Creates an M3U playlist file for all media files in a given folder.
    """
    media_files = [f for f in os.listdir(folder_path) if f.endswith(('.avs'))]
    # pprint([x for x in media_files if pref_substr in x])
    # Sort the list using the modification time as the key and reverse=True for descending order
    # media_files.sort(key=lambda f: sort_key), reverse=True)
    # media_file_idxs = sorted(enumerate(media_files)
    #                      , key=lambda enum_tuple: sort_key(enum_tuple[0], enum_tuple[1], folder_path=folder_path)
    #                      , reverse=False)
    for fidx, fn in enumerate(media_files):
        sort_key(fidx, fn, folder_path)
    media_files_sorted_zipped = sorted(zip(media_files, sort_tuples)
                         , key=lambda fln_sort_tpl: (fln_sort_tpl[1][0], fln_sort_tpl[1][1]), reverse=False)
    # pprint([x for x in media_files_sorted_zipped if pref_substr in x[0]])
    media_files, _ = zip(*media_files_sorted_zipped)
    pprint(media_files)
    with open(output_filename, 'w', encoding='utf-8') as f:
        f.write("#EXTM3U\n")
        for media_file in media_files:
            # Use absolute path for robustness
            full_path = os.path.join(folder_path, media_file)
            # PotPlayer handles Windows paths correctly
            f.write(f"{full_path}\n")
            
    print(f"Created playlist file: {os.path.abspath(output_filename)}")

# create_m3u_playlist("P:\\all_scripts\\global_rand_3d_playlist\\avs")
create_m3u_playlist(".\\avs")
