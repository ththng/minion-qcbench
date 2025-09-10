#!/bin/bash

# Dynamic QC Tools and Assemblers Pipeline Wrapper
# This script supports two modes:
# 1. GENERATE: Install modules, generate dynamic code, prepare for execution
# 2. EXECUTE: Run the Nextflow pipeline with generated configuration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to show usage
show_usage() {
    echo -e "${BLUE}Dynamic QC Tools and Assemblers Pipeline Wrapper${NC}"
    echo "=" | tr '\n' '=' | head -c 60; echo
    echo
    echo -e "${CYAN}Usage:${NC}"
    echo "  $0 generate                    # Install modules and generate dynamic code"
    echo "  $0 execute [nextflow_args...]  # Execute Nextflow pipeline"
    echo "  $0 run [nextflow_args...]      # Legacy: generate + execute in one step"
    echo
    echo -e "${CYAN}Workflow:${NC}"
    echo "  1. Configure tools in conf/tools_config.yml"
    echo "  2. Run '$0 generate' to install modules and generate code"
    echo "  3. Review/modify conf/modules.config if needed"
    echo "  4. Run '$0 execute [args...]' to execute the pipeline"
    echo
    echo -e "${CYAN}Examples:${NC}"
    echo "  $0 generate"
    echo "  $0 execute -profile test,singularity --input data/samplesheet.csv --outdir results"
    echo "  $0 execute --input data/samplesheet.csv --outdir results --quality_scores 13,15 --flye_modes nano-corr,nano-hq"
    echo "  $0 run -profile test  # Legacy mode"
    echo
}

# Check command line arguments
if [[ $# -eq 0 ]]; then
    show_usage
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    "generate")
        MODE="GENERATE"
        ;;
    "execute")
        MODE="EXECUTE"
        NEXTFLOW_ARGS=("$@")
        ;;
    "run")
        MODE="LEGACY"
        NEXTFLOW_ARGS=("$@")
        ;;
    "-h"|"--help"|"help")
        show_usage
        exit 0
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$COMMAND'${NC}"
        echo
        show_usage
        exit 1
        ;;
esac

echo -e "${BLUE}Dynamic QC Tools and Assemblers Pipeline Wrapper${NC}"
echo -e "${CYAN}Mode: $MODE${NC}"
echo "=" | tr '\n' '=' | head -c 60; echo

# Check if yq is available for YAML parsing
if ! command -v yq &> /dev/null; then
    echo -e "${RED}Error: 'yq' is required but not installed.${NC}"
    echo "Please install yq: https://github.com/mikefarah/yq"
    exit 1
fi

# Check if nf-core is available for module installation
if ! command -v nf-core &> /dev/null; then
    echo -e "${RED}Error: 'nf-core' is required but not installed.${NC}"
    echo "Please install nf-core: pip install nf-core"
    exit 1
fi

# Function to process templates with variable substitution
process_template() {
    local template_file="$1"
    local module_name="$2"

    if [[ ! -f "$template_file" ]]; then
        echo -e "${RED}Template file not found: $template_file${NC}"
        exit 1
    fi

    # Replace {{MODULE_NAME}} with actual module name
    sed "s/{{MODULE_NAME}}/$module_name/g" "$template_file"
}

# Function to check if a module exists
module_exists() {
    local module_path="$1"
    # Convert relative path to absolute path from project root
    local full_path="${module_path#../../../}"
    [[ -f "$full_path/main.nf" ]]
}

# Function to install nf-core module
install_nf_core_module() {
    local module_name="$1"
    local module_path="$2"

    echo -e "${YELLOW}Installing nf-core module: $module_name${NC}"

    # Extract just the module name (lowercase) for nf-core install command
    local install_name=$(echo "$module_name" | tr '[:upper:]' '[:lower:]')

    # Run nf-core modules install command
    if nf-core modules install "$install_name"; then
        echo -e "${GREEN}Successfully installed module: $module_name${NC}"
        return 0
    else
        echo -e "${RED}Failed to install module: $module_name${NC}"
        echo -e "${YELLOW}Please check if the module name is correct or install manually${NC}"
        return 1
    fi
}

# Function to ensure all required modules are installed
ensure_modules_installed() {
    local tools_array=("$@")
    local missing_modules=()
    local failed_installs=()

    echo -e "${BLUE}Checking module availability...${NC}"

    for tool_name in "${tools_array[@]}"; do
        local module_name=$(yq eval ".qc_tools.${tool_name}.module // .assemblers.${tool_name}.module" "$CONFIG_FILE")
        local module_path=$(yq eval ".qc_tools.${tool_name}.module_path // .assemblers.${tool_name}.module_path" "$CONFIG_FILE")

        if [[ "$module_name" != "null" && "$module_path" != "null" ]]; then
            if ! module_exists "$module_path"; then
                # Skip local modules (they should already exist)
                if [[ "$module_path" == *"/local/"* ]]; then
                    echo -e "${YELLOW}Warning: Local module not found: $module_path${NC}"
                    echo -e "${YELLOW}Please ensure local modules are properly created${NC}"
                    continue
                fi

                missing_modules+=("$tool_name:$module_name:$module_path")
            else
                echo -e "${GREEN}✓ Module exists: $module_name${NC}"
            fi
        fi
    done

    # Install missing modules
    if [[ ${#missing_modules[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Found ${#missing_modules[@]} missing modules. Installing...${NC}"

        for module_info in "${missing_modules[@]}"; do
            IFS=':' read -r tool_name module_name module_path <<< "$module_info"

            if ! install_nf_core_module "$module_name" "$module_path"; then
                failed_installs+=("$tool_name")
            fi
        done

        # Check for installation failures
        if [[ ${#failed_installs[@]} -gt 0 ]]; then
            echo -e "${RED}Failed to install modules for the following tools:${NC}"
            for tool in "${failed_installs[@]}"; do
                echo -e "${RED}  - $tool${NC}"
            done
            echo -e "${YELLOW}Please install these modules manually or disable them in $CONFIG_FILE${NC}"
            return 1
        fi

        echo -e "${GREEN}All missing modules installed successfully!${NC}"
    else
        echo -e "${GREEN}All required modules are already available${NC}"
    fi

    return 0
}

# Configuration
CONFIG_FILE="conf/tools_config.yml"
QC_HELPER_FILE="subworkflows/local/qc_tool_executor_helper/main.nf"
ASSEMBLER_HELPER_FILE="subworkflows/local/assembler_executor_helper/main.nf"
QC_BACKUP_FILE="${QC_HELPER_FILE}.backup"
ASSEMBLER_BACKUP_FILE="${ASSEMBLER_HELPER_FILE}.backup"

echo -e "${YELLOW}Loading QC tools and assemblers configuration...${NC}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

if [[ ! -f "$QC_HELPER_FILE" ]]; then
    echo -e "${RED}QC helper file not found: $QC_HELPER_FILE${NC}"
    exit 1
fi

if [[ ! -f "$ASSEMBLER_HELPER_FILE" ]]; then
    echo -e "${RED}Assembler helper file not found: $ASSEMBLER_HELPER_FILE${NC}"
    exit 1
fi

# Create backups for safety (but won't restore for debugging purposes)
cp "$QC_HELPER_FILE" "$QC_BACKUP_FILE"
cp "$ASSEMBLER_HELPER_FILE" "$ASSEMBLER_BACKUP_FILE"

# Process QC Tools
echo -e "${BLUE}Processing QC Tools...${NC}"

QC_IMPORTS=""
QC_SWITCH_CASES=""
ENABLED_QC_TOOLS=()

# Get all enabled QC tools
while IFS= read -r tool_name; do
    if [[ -n "$tool_name" ]]; then
        ENABLED_QC_TOOLS+=("$tool_name")

        # Get module name and path for this tool
        MODULE_NAME=$(yq eval ".qc_tools.${tool_name}.module" "$CONFIG_FILE")
        MODULE_PATH=$(yq eval ".qc_tools.${tool_name}.module_path" "$CONFIG_FILE")

        if [[ "$MODULE_NAME" != "null" && "$MODULE_PATH" != "null" ]]; then
            QC_IMPORTS="${QC_IMPORTS}include { ${MODULE_NAME} } from '${MODULE_PATH}'\n"

            # Generate switch case using template
            QC_SWITCH_CASE=$(process_template "templates/qc_tool_switch_case.template" "$MODULE_NAME")
            QC_SWITCH_CASES="${QC_SWITCH_CASES}${QC_SWITCH_CASE}\n"
        fi
    fi
done < <(yq eval '.qc_tools | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE")

# Process Assemblers
echo -e "${BLUE}Processing Assemblers...${NC}"

ASSEMBLER_IMPORTS=""
ASSEMBLER_SWITCH_CASES=""
ENABLED_ASSEMBLERS=()

# Get all enabled assemblers
while IFS= read -r assembler_name; do
    if [[ -n "$assembler_name" ]]; then
        ENABLED_ASSEMBLERS+=("$assembler_name")

        # Get module name and path for this assembler
        MODULE_NAME=$(yq eval ".assemblers.${assembler_name}.module" "$CONFIG_FILE")
        MODULE_PATH=$(yq eval ".assemblers.${assembler_name}.module_path" "$CONFIG_FILE")

        if [[ "$MODULE_NAME" != "null" && "$MODULE_PATH" != "null" ]]; then
            ASSEMBLER_IMPORTS="${ASSEMBLER_IMPORTS}include { ${MODULE_NAME} } from '${MODULE_PATH}'\n"

            # Generate switch case using template
            ASSEMBLER_SWITCH_CASE=$(process_template "templates/assembler_switch_case.template" "$MODULE_NAME")
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}${ASSEMBLER_SWITCH_CASE}\n"
        fi
    fi
done < <(yq eval '.assemblers | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE")

# Remove trailing newlines (cross-platform compatible)
QC_IMPORTS=$(printf "%s" "$QC_IMPORTS")
QC_SWITCH_CASES=$(printf "%s" "$QC_SWITCH_CASES")
ASSEMBLER_IMPORTS=$(printf "%s" "$ASSEMBLER_IMPORTS")
ASSEMBLER_SWITCH_CASES=$(printf "%s" "$ASSEMBLER_SWITCH_CASES")

echo -e "${GREEN}Found ${#ENABLED_QC_TOOLS[@]} enabled QC tools:${NC}"
for tool in "${ENABLED_QC_TOOLS[@]}"; do
    echo "   - $tool"
done

echo -e "${GREEN}Found ${#ENABLED_ASSEMBLERS[@]} enabled assemblers:${NC}"
for assembler in "${ENABLED_ASSEMBLERS[@]}"; do
    echo "   - $assembler"
done

# Function to generate dynamic code
generate_dynamic_code() {
    # Update QC helper file with dynamic imports
    echo -e "\n${YELLOW}Updating QC helper file with dynamic imports...${NC}"

    # Create a temporary file for QC tools
    QC_TEMP_FILE=$(mktemp)

    # Read the QC helper file and replace imports and switch cases sections
    while IFS= read -r line; do
        if [[ "$line" == *"// DYNAMIC_IMPORTS_START"* ]]; then
            echo "$line" >> "$QC_TEMP_FILE"
            echo -e "$QC_IMPORTS" >> "$QC_TEMP_FILE"
            # Skip lines until we find the end marker
            while IFS= read -r line; do
                if [[ "$line" == *"// DYNAMIC_IMPORTS_END"* ]]; then
                    echo "$line" >> "$QC_TEMP_FILE"
                    break
                fi
            done
        elif [[ "$line" == *"// DYNAMIC_SWITCH_CASES_START"* ]]; then
            echo "$line" >> "$QC_TEMP_FILE"
            echo -e "$QC_SWITCH_CASES" >> "$QC_TEMP_FILE"
            # Skip lines until we find the end marker
            while IFS= read -r line; do
                if [[ "$line" == *"// DYNAMIC_SWITCH_CASES_END"* ]]; then
                    echo "$line" >> "$QC_TEMP_FILE"
                    break
                fi
            done
        else
            echo "$line" >> "$QC_TEMP_FILE"
        fi
    done < "$QC_HELPER_FILE"

    # Replace the original QC file
    mv "$QC_TEMP_FILE" "$QC_HELPER_FILE"

    echo -e "${GREEN}Updated $QC_HELPER_FILE with dynamic imports${NC}"

    # Update Assembler helper file with dynamic imports
    echo -e "\n${YELLOW}Updating assembler helper file with dynamic imports...${NC}"

    # Create a temporary file for assemblers
    ASSEMBLER_TEMP_FILE=$(mktemp)

    # Read the assembler helper file and replace imports and switch cases sections
    while IFS= read -r line; do
        if [[ "$line" == *"// DYNAMIC_IMPORTS_START"* ]]; then
            echo "$line" >> "$ASSEMBLER_TEMP_FILE"
            echo -e "$ASSEMBLER_IMPORTS" >> "$ASSEMBLER_TEMP_FILE"
            # Skip lines until we find the end marker
            while IFS= read -r line; do
                if [[ "$line" == *"// DYNAMIC_IMPORTS_END"* ]]; then
                    echo "$line" >> "$ASSEMBLER_TEMP_FILE"
                    break
                fi
            done
        elif [[ "$line" == *"// DYNAMIC_SWITCH_CASES_START"* ]]; then
            echo "$line" >> "$ASSEMBLER_TEMP_FILE"
            echo -e "$ASSEMBLER_SWITCH_CASES" >> "$ASSEMBLER_TEMP_FILE"
            # Skip lines until we find the end marker
            while IFS= read -r line; do
                if [[ "$line" == *"// DYNAMIC_SWITCH_CASES_END"* ]]; then
                    echo "$line" >> "$ASSEMBLER_TEMP_FILE"
                    break
                fi
            done
        else
            echo "$line" >> "$ASSEMBLER_TEMP_FILE"
        fi
    done < "$ASSEMBLER_HELPER_FILE"

    # Replace the original assembler file
    mv "$ASSEMBLER_TEMP_FILE" "$ASSEMBLER_HELPER_FILE"

    echo -e "${GREEN}Updated $ASSEMBLER_HELPER_FILE with dynamic imports${NC}"
}

# Execute based on mode
case "$MODE" in
    "GENERATE")
        # Ensure all required modules are installed
        echo -e "\n${BLUE}Ensuring all required modules are installed...${NC}"
        ALL_TOOLS=("${ENABLED_QC_TOOLS[@]}" "${ENABLED_ASSEMBLERS[@]}")
        if ! ensure_modules_installed "${ALL_TOOLS[@]}"; then
            echo -e "${RED}Module installation failed. Exiting.${NC}"
            exit 1
        fi

        # Generate dynamic code
        generate_dynamic_code

        echo -e "\n${GREEN}✅ Generation phase completed successfully!${NC}"
        echo -e "${CYAN}Next steps:${NC}"
        echo -e "  1. Review/modify conf/modules.config if needed"
        echo -e "  2. Run: $0 execute [nextflow_args...] to execute the pipeline"
        echo -e "\n${BLUE}Generated files:${NC}"
        echo -e "  - $QC_HELPER_FILE (with dynamic QC tool imports)"
        echo -e "  - $ASSEMBLER_HELPER_FILE (with dynamic assembler imports)"
        echo -e "  - Backup files: $QC_BACKUP_FILE, $ASSEMBLER_BACKUP_FILE"
        ;;

    "EXECUTE")
        # Check if dynamic code has been generated
        if ! grep -q "include { " "$QC_HELPER_FILE" 2>/dev/null || ! grep -q "include { " "$ASSEMBLER_HELPER_FILE" 2>/dev/null; then
            echo -e "${RED}Error: Dynamic code not found in helper files.${NC}"
            echo -e "${YELLOW}Please run '$0 generate' first to install modules and generate code.${NC}"
            exit 1
        fi

        echo -e "\n${BLUE}Running Nextflow pipeline...${NC}"
        echo "Command: nextflow ${NEXTFLOW_ARGS[*]}"
        nextflow "${NEXTFLOW_ARGS[@]}"
        ;;

    "LEGACY")
        # Legacy mode: generate + execute in one step
        echo -e "${YELLOW}Running in legacy mode (generate + execute)${NC}"

        # Ensure all required modules are installed
        echo -e "\n${BLUE}Ensuring all required modules are installed...${NC}"
        ALL_TOOLS=("${ENABLED_QC_TOOLS[@]}" "${ENABLED_ASSEMBLERS[@]}")
        if ! ensure_modules_installed "${ALL_TOOLS[@]}"; then
            echo -e "${RED}Module installation failed. Exiting.${NC}"
            exit 1
        fi

        # Generate dynamic code
        generate_dynamic_code

        echo -e "\n${BLUE}Running Nextflow pipeline...${NC}"
        echo "Command: nextflow ${NEXTFLOW_ARGS[*]}"
        nextflow "${NEXTFLOW_ARGS[@]}"
        ;;
esac
