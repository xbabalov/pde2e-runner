#!/bin/bash

# Versions variables
nodeVersion="v22.14.0"
gitVersion="2.42.0"

declare -a script_env_vars

pdUrl=""
pdPath=""
targetFolder=""
resultsFolder="results"
fork="podman-desktop"
branch="main"
extTests=0
extRepo=""
extFork=""
extBranch=""
npmTarget="test:e2e"
podmanPath=""
initialize=0
start=0
rootful=0
envVars=""
secretFile=""
podmanProvider=""
saveTraces=1
cleanMachine=1

while [[ $# -gt 0 ]]; do
    case $1 in
        --pdUrl) pdUrl="$2"; shift ;;
        --pdPath) pdPath="$2"; shift ;;
        --targetFolder) targetFolder="$2"; shift ;;
        --resultsFolder) resultsFolder="$2"; shift ;;
        --fork) fork="$2"; shift ;;
        --branch) branch="$2"; shift ;;
        --extRepo) extRepo="$2"; shift ;;
        --extTests) extTests="$2"; shift ;;
        --extFork) extFork="$2"; shift ;;
        --extBranch) extBranch="$2"; shift ;;
        --npmTarget) npmTarget="$2"; shift ;;
        --podmanPath) podmanPath="$2"; shift ;;
        --initialize) initialize="$2"; shift ;;
        --start) start="$2"; shift ;;
        --rootful) rootful="$2"; shift ;;
        --envVars) envVars="$2"; shift ;;
        --secretFile) secretFile="$2"; shift ;;
        --podmanProvider) podmanProvider="$2"; shift ;;
        --saveTraces) saveTraces="$2"; shift ;;
        --cleanMachine) cleanMachine="$2"; shift ;;
        *) ;;
    esac
    shift
done

# Functions
download_pd() {
    echo "Downloading Podman Desktop from $pdUrl"
    curl -L "$pdUrl" -o pd.exe
}

echo "Reading envVars in script: '$envVars'"

# Create a env. vars from a string: VAR=VAL,VAR2=VAL
function load_variables() {
    echo "Loading Variables passed into image"
    echo "Env. Vars String: '$envVars'"
    # Check if the input string is not null or empty
    if [ -n "$envVars" ]; then
        # use input field separator
        IFS=',' read -ra VARIABLES <<< "$envVars"

        for var in "${VARIABLES[@]}"; do
            echo "Processing $var"
            # Split each variable definition
            IFS='=' read -r name value <<< "$var"

            # Check if the variable assignment is in VAR=Value format
            if [ -n "$value" ]; then
                # Set the environment variable
                export "$name"="$value"
                newValue="${!name}"
                script_env_vars+=("$name")
            else
                echo "Invalid variable assignment: $variable"
            fi
        done
    else
        echo "Input string is empty."
    fi
    # check if we have explicit podman provider env. var. added
    if [ -n "$podmanProvider" ]; then
        echo "Settings CONTAINERS_MACHINE_PROVIDER: $podmanProvider"
        export CONTAINERS_MACHINE_PROVIDER=$podmanProvider
        script_env_vars+=("CONTAINERS_MACHINE_PROVIDER")
    fi
}

# Loading a secrets into env. vars from the file
function load_secrets() {
    if [ -n "$secretFile" ]; then
        secretFilePath="$resourcesPath/$secretFile"
        if [ -f $secretFilePath ]; then
            echo "Loading Secrets from file: $secretFilePath"
            if [ -f "$secretFilePath" ]; then
                while IFS='=' read -r key value || [ -n "$key" ]; do
                    # Ignore comments and empty lines
                    if [[ ! $key =~ ^\s*# && -n $key ]]; then
                        # Trim leading and trailing whitespaces
                        key=$(echo "$key" | sed 's/^[ \t]*//;s/[ \t]*$//')
                        value=$(echo "$value" | sed 's/^[ \t]*//;s/[ \t]*$//')
                        # Set the environment variable
                        export "$key"="$value"
                        script_env_vars+=("$key")
                    fi
                done < "$secretFilePath"
                echo "Secrets loaded from '$secretFilePath' and set as environment variables."
            else
                echo "File '$secretFilePath' not found."
            fi
        else
            echo "Secret File path $secretFilePath does not exist"
        fi
    else 
        echo "Secret file Parameter not set"
    fi
}

# Loading a secrets into env. vars from the file
function clone_checkout() {
    # Checkout Podman Desktop if it does not exist
    local_repo=$1
    local_fork=$2
    local_branch=$3
    echo "Working Dir: $workingDir"
    cd $workingDir
    echo "Cloning $local_repo"
    if [ -d $local_repo ]; then
        echo "$local_repo github repo exists"
    else
        repositoryURL="https://github.com/$local_fork/$local_repo.git"
        echo "Checking out $repositoryURL"
        git clone $repositoryURL
    fi

    cd $local_repo || exit
    echo "Fetching all branches and tags"
    git fetch --all
    echo "Checking out branch: $local_branch"
    git checkout $local_branch
}

function copy_exists() {
    source=$1
    target=$2
    if [ -e $source ]; then
        echo "Copying files from $source to $target"
        cp -r $source $target
    else 
        echo "Path $source does not exist"
    fi
}

function collect_logs() {
    folder="$1"
    mkdir -p "$workingDir/$resultsFolder/$folder"
    target="$workingDir/$resultsFolder/$folder"
    echo "Collecting the results into: " $target
    # copy all junit xml files into target and rename them by the folder the were in
    junits=$(find $workingDir/$folder -name "junit*.xml")
    echo "Found Junit files: $junits"
    for junit in $junits; do
        target_path="$workingDir/$resultsFolder/junit-$folder.xml"
        echo "Copying $junit and renaming to $target_path"
        cp "$junit" $target_path
    done
    if (( extTests == 1 )); then
        echo "Removing possible models from working directories"
        rm -rf "$workingDir/$folder/**/*.gguf"
    fi
    
    copy_exists "$workingDir/$folder/output.log" $target
    copy_exists "$workingDir/$folder/tests/output/" $target
    copy_exists "$workingDir/$folder/tests/playwright/output/" $target
    copy_exists "$workingDir/$folder/tests/playwright/tests/output/" $target
    # reduce the size of the artifacts
    if [ -d "$target/traces" ]; then
        echo "Removing raw playwright trace files"
        rm -r "$target/traces/raw"
        if (( saveTraces == 0)); then
            echo "Removing all traces from test artifacts, mainly due capacity reasons"
            rm -rf "$target/traces"
        fi
    fi
}


echo "Podman desktop E2E runner script is being run..."

if [ -z "$targetFolder" ]; then
    echo "Error: targetFolder is required"
    exit 1
fi

echo "Switching to a target folder: $targetFolder"
cd "$targetFolder" || exit
echo "Create a resultsFolder in targetFolder: $resultsFolder"
mkdir -p "$resultsFolder"
workingDir=$(pwd)
echo "Working location: $workingDir"

# Specify the user profile directory
userProfile="$HOME"

# Specify the shared tools directory
toolsInstallDir="$userProfile/tools"

# Output file for built podman desktop binary
outputFile="pde2e-binary-path.log"

# Determine the system's arch
architecture=$(uname -m)

resourcesPath=$workingDir

# Loading env. vars
load_variables

# load secrets
load_secrets

# Create the tools directory if it doesn't exist
if [ ! -d "$toolsInstallDir" ]; then
    mkdir -p "$toolsInstallDir"
fi

# node installation
if ! command -v node &> /dev/null; then
    # architecture in [arm64, x86_64]
    # node arch strings in [arm64, x64]
    nodeArch=""
    if [ "$architecture" == "x86_64" ]; then
        nodeArch="x64"
    elif [ "$architecture" == "arm64" ]; then
        nodeArch="arm64"
    else
        echo "Error: Unsupported architecture $architecture"
        exit 1
    fi
    nodeUrl="https://nodejs.org/download/release/$nodeVersion/node-$nodeVersion-darwin-$nodeArch.tar.xz"

    # Check if Node.js is already installed
    echo "$(ls $toolsInstallDir)"
    if [ ! -d "$toolsInstallDir/node-$nodeVersion-darwin-$nodeArch" ]; then
        # Download and install Node.js
        echo "Installing node $nodeVersion for $architecture architecture"
        echo "curl -O $nodeUrl | tar -xJ -C $toolsInstallDir"
        curl -o "$toolsInstallDir/node.tar.xz" "$nodeUrl" 
        tar -xf $toolsInstallDir/node.tar.xz -C $toolsInstallDir
    fi
    if [ -d "$toolsInstallDir/node-$nodeVersion-darwin-${nodeArch}/bin" ]; then
        echo "Node Installation path found"
        export PATH="$PATH:$toolsInstallDir/node-$nodeVersion-darwin-${nodeArch}/bin"
    else
        echo "Node installation path not found"
    fi
fi

# node and npm version check
echo "Node.js Version: $(node -v)"
echo "npm Version: $(npm -v)"

if ! command -v git &> /dev/null; then
    # Check if Git is already installed
    if [ ! -d "$toolsInstallDir/git-$gitVersion" ]; then
        # Download and install Git
        echo "Installing git $gitVersion"
        gitUrl="https://github.com/git/git/archive/refs/tags/v$gitVersion.tar.gz"
        mkdir -p "$toolsInstallDir/git-$gitVersion"
        curl -O "$gitUrl" | tar -xz -C "$toolsInstallDir/git-$gitVersion" --strip-components 1
        cd "$toolsInstallDir/git-$gitVersion" || exit
        make prefix="$toolsInstallDir/git-$gitVersion" all
        make prefix="$toolsInstallDir/git-$gitVersion" install
    fi
    export PATH="$PATH:$toolsInstallDir/git-$gitVersion/bin"
fi

# git verification
git --version

# Install pnpm
echo "Installing pnpm"
sudo npm install -g pnpm@9
echo "pnpm Version: $(pnpm --version)"

# Podman desktop binary
podmanDesktopBinary=""

if [ -z "$pdPath" ]; then
    if [ -n "$pdUrl" ]; then
        Download_PD
        podmanDesktopBinary="$workingDir/pd.exe"
    fi
else
    podmanDesktopBinary="$pdPath"
fi

# Setup Podman
if [ -n "$podmanPath" ] && ! command -v podman &> /dev/null; then
    echo "Podman is not installed..."
    echo "Settings podman binary location to PATH"
    export PATH="$PATH:$podmanPath"
else
    echo "Warning: Podman nor Podman Path is specified!"
    # exit 1;
fi

# Configure Podman Machine
if (( initialize == 1 )); then
    flags=""
    if (( rootful == 1 )); then
        flags+="--rootful "
    fi
    flags=$(echo "$flags" | awk '{$1=$1};1')
    flagsArray=($flags)
    echo "Initializing podman machine, command: podman machine init $flags"
    logFile="$workingDir/$resultsFolder/podman-machine-init.log"
    echo "podman machine init $flags" > "$logFile"
    if (( ${#flagsArray[@]} > 0 )); then
        podman machine init "${flagsArray[@]}" 2>&1 | tee -a "$logFile"
    else
        podman machine init 2>&1 | tee -a "$logFile"
    fi
    if (( start == 1 )); then
        echo "Starting podman machine..."
        echo "podman machine start --log-level=debug" >> "$logFile"
        podman machine start 2>&1 | tee -a "$logFile"
    fi
    podman machine ls --format json 2>&1 | tee -a "$logFile"
fi

# Checkout Podman Desktop
clone_checkout "podman-desktop" $fork $branch

if (( extTests == 1 )); then
    # Checkout Podman Desktop if it does not exist
    clone_checkout $extRepo $extFork $extBranch
fi

if [ -n "$podmanDesktopBinary" ]; then
    export PODMAN_DESKTOP_BINARY="$podmanDesktopBinary"
elif (( extTests == 1 )); then
    export PODMAN_DESKTOP_ARGS="$workingDir/podman-desktop"
fi

export CI=true
testsOutputLog="$workingDir/$resultsFolder/tests.log"
cd "$workingDir/podman-desktop"
echo "Installing dependencies storing pnpm run output in: $testsOutputLog"
pnpm install --frozen-lockfile 2>&1 | tee -a $testsOutputLog
if (( extTests == 0 )); then
    echo "Running the e2e playwright tests using target: $npmTarget, binary used: $podmanDesktopBinary"
    pnpm "$npmTarget" 2>&1 | tee -a $testsOutputLog
    collect_logs "podman-desktop"
else
    echo "Building podman-desktop for extension e2e tests"
    pnpm test:e2e:build 2>&1 | tee -a $testsOutputLog
fi

## run extension e2e tests
if (( extTests == 1 )); then
    cd "$workingDir/$extRepo"
    echo "Add latest version of the @podman-desktop/tests-playwright into right package.json"
    if [ -d "$workingDir/$extRepo/tests/playwright" ]; then
        cd tests/playwright
    fi
    pnpm add -D @podman-desktop/tests-playwright@next
    cd "$workingDir/$extRepo"
    echo "Installing dependencies of $extRrepo"
    pnpm install --frozen-lockfile 2>&1 | tee -a $testsOutputLog
    echo "Running the e2e playwright tests using target: $npmTarget"
    pnpm $npmTarget 2>&1 | tee -a $testsOutputLog
    ## Collect results
    collect_logs $extRepo
fi

# Cleaning up, env vars - secrets
echo "Cleaning the host"
unset "${script_env_vars[@]}"

# Remove secrets file
if [ -f "$resourcesPath/$secretFile" ]; then
    echo "Removing secrets file: $resourcesPath/$secretFile"
    rm "$resourcesPath/$secretFile"
fi

if (( cleanMachine == 1 )); then
    echo "Cleaning up the podman machines"
    podman machine reset -f
fi

composeBinary=$(which docker-compose)
if [ -f "$composeBinary" ]; then
    echo "Removing compose binary file"
    sudo rm "$composeBinary"
fi 

kubectlBinary=$(which kubectl)
if [ -f "$kubectlBinary" ]; then
    echo "Removing kubectl binary file"
    sudo rm "$kubectlBinary"
fi 

kindBinary=$(which kind)
if [ -f "$kindBinary" ]; then
    echo "Removing kind binary file"
    sudo rm "$kindBinary"
fi 

minikubeBinary=$(which minikube)
if [ -f "$minikubeBinary" ]; then
    echo "Removing minikube binary file"
    sudo rm "$minikubeBinary"
fi 

echo "Script finished..."
