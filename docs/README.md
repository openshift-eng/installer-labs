# installer-labs | A Development Playground

`installer-labs` is a repository created for developers exercise the different
OpenShift variants, specially the ones requires automation. Here is a friendly
place to save quickly step to help each-other quickly achieve more complex scenarios.

DISCLAIMER: Any automation in this repository is supported by the OpenShift product engineering.

## How To Use

This repository hosts scripts to quickly usage to achive complex scenarios while installing OpenShift.

Here are some ideas how to organize the repo for this shared environment, although it isn't static,
feel free to propose what works for you and your peers:

- `installer-upi` is mostly automation assets used to provision infrastructure to create an OpenShift cluster. Similar to `upi/` directory of installer repo, but with many customizations (IaaC, scripts, AWS CloudFormation, terraform, etc, etc).
- `docs`: minumum documentation instruction how to use the automation for the variant.
- `labs`: hosts any other script, solution, hacking, or automation that does not fit directly with infra automation for installer


