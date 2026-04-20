I'm trying to secure my three machines with root A/B switching and prevent configuration drift and prevent persistent vulnerability threats. I am experimenting using mkosi as a solution for this (migration from a huge Ansible solution I have been maintaining for years).

Here's the project so far: https://github.com/bashirsouid/debian-system-image-provisioning

Check the overal security posture of the project, if there are missing TODOs that should be added to the README, if there are functionalities that are not documented in the readme (ex: what bash scripts do, what flags for bash scripts, etc). Also if there are any files that should be blocked with gitignore then update the file and give me the commands to remove old cached references.

Implement any fixes and always publish a working git patch against the latest version of master on Github (not necessarily the same as the local files you have in your workspace if you haven't pulled latest recently).