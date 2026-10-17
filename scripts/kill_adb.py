#unicode: utf-8


import subprocess
import time


def main():
    while True:
        subprocess.run("taskkill /f /im adb.exe", check=False)
        time.sleep(3)

if __name__ == "__main__":
    main()