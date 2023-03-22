# Replace 'urls.txt' with the path to your text file containing URLs
import os
import time

with open('/content/urls.txt', 'r') as f, open('/content/parsed_urls.log', 'a') as log_file:
    for line in f:
        # Remove leading/trailing whitespaces and newlines
        url = line.strip()
        # Execute the command with the URL
        os.system(f"/content/mangadex-dl/mdex_dl.tcl {url} covers")
        time.sleep(5)
        # Write the URL to the log file
        log_file.write(url + '\n')
