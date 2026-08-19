import os
import shutil
from pathlib import Path


latest_n = 110	# approximates no. of lines in 2d_media_paths.txt


def retain_newest_files(directory_path, num_to_keep):
    """
    Retains only the N newest files in the specified directory, deleting older ones.

    Args:
        directory_path (str or Path): The path to the directory to manage.
        num_to_keep (int): The number of newest files to keep.
    """
    p = Path(directory_path)
    if not p.is_dir():
        print(f"Error: Directory not found at '{directory_path}'")
        return

    # Get all files in the directory and sort by modification time (newest first)
    # Using entry.stat().st_mtime is a reliable way to sort by modification time.
    files = sorted(
        (entry for entry in p.iterdir() if entry.is_file()),
        key=lambda entry: entry.stat().st_mtime,
        reverse=True
    )

    # Identify files to delete (everything beyond the newest N)
    files_to_delete = files[num_to_keep:]

    if not files_to_delete:
        print(f"No files to delete. Total files: {len(files)}")
        return

    print(f"Found {len(files)} files. Deleting {len(files_to_delete)} older files...")

    # Delete the excess files
    for file_path in files_to_delete:
        try:
            file_path.unlink()  # Deletes the file
            print(f"  Deleted: {file_path.name}")
        except OSError as e:
            print(f"  Error deleting {file_path.name}: {e}")

    print(f"Cleanup complete. Total files remaining: {num_to_keep}")


# --- Usage ---
directory_to_clean = "avs"
retain_newest_files(directory_to_clean, num_to_keep=latest_n)
directory_to_clean = "op_logs"
retain_newest_files(directory_to_clean, num_to_keep=latest_n)


def retain_top_n_lines(file_path, n):
    """
    Retains only the top n lines in the specified file.
    
    Args:
        file_path (str): The path to the file.
        n (int): The number of top lines to retain.
    """
    temp_file_path = file_path + '.temp'
    
    # Open the original file for reading and the temporary file for writing
    with open(file_path, 'r', encoding='utf-8') as f_in, open(temp_file_path, 'w', encoding='utf-8') as f_out:
        for i, line in enumerate(f_in):
            if i < n:
                f_out.write(line)
            else:
                # Stop reading once n lines are processed
                break
    
    print(f"Truncated {file_path}! Retained newest {n} lines")
    # Replace the original file with the temporary file
    shutil.move(temp_file_path, file_path)


# --- Usage ---
retain_top_n_lines('playlist.m3u', latest_n)
# retain_top_n_lines('2d_media_paths.txt', latest_n)
