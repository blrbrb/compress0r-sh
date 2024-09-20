#!/bin/bash


#!/bin/bash

# Ensure the consistency of compressions and make sure that we don't re-process a file that has already been processed
# (unless we're aiming for two-pass, tbd)
 trackFile() {
    local file_path="$1"
    local file_hash
    file_hash=$(md5sum "$file_path" | awk '{print $1}')

    # Check if the file path and its hash exist in the cache
    if grep -q "$file_hash" "$cache_file"; then
        return 0
    else
        return 1
    fi
}



# Directory containing the input files
if [ -z "$1" ]; then
echo "Uses ffmpeg and (hardware acceleration if avalible) to compress a directory of video files"
	echo "Usage: $(basename "$0") [options] <arguments> "
	echo "Options:"
	echo "-i, --input	The source directory of uncompressed source videos. If no value is supplied, a prompt appear before the script attempts to run in the current directory"
	echo "-o, --output  An output directory for the optimized videos. By default, creates a new folder within the input directory"
	echo "-k, --keep-original-filenames  When specified, the output videos will retain the same name as the input files (default off)"
	echo "-p, --write-in-place  When specified, source videos will be overwritten by the output videos without creating copies (default off)"

	echo "Example:"
	echo "		compressor '/home/user/Videos/Downloads' "
	exit 1
else
    input_dir="$1"
fi


# ensure that the first argument is a valid directory
if [ ! -d "$input_dir" ]; then
    echo "$input_dir Does not exist or does not contain any valid video files. exiting..."
    exit 1
fi

# Define an array of valid video extensions
video_extensions=("mp4" "avi" "mkv" "mov" "flv" "webm" "gif")

# Create a default video filter (will pass nullsrc to -vf if the video does not need to be resized)
resize="null"

#setup tmpdir, and logging
tempd=$(mktemp -d)
logd="$tempd/compressor.log"
# Set up variables for the cache folder and file
cache_dir="$HOME/.cache/compressor"
cache_file="$cache_dir/processed.txt"
original_size=$(du -sh "$input_dir" | awk '{print $1}')

# Create cache directory if it doesn't exist
if [[ ! -d "$cache_dir" ]]; then
    mkdir -p "$cache_dir"
fi

# Create cache file if it doesn't exist
if [[ ! -f "$cache_file" ]]; then
    touch "$cache_file"
fi


touch $logd
echo $logd

# determine the original size of the starting directory, for easy compression comparison metrics



# if no output dir has been specified, write to a new directory within the source directory
if [ -z "$2" ]; then
    output_dir=$(mktemp -d)
else
    output_dir="$2"
fi
mkdir -p "$output_dir"
# Give the user some information about where new files will be written, and ask for permission to continue
read -p "Compressed files will be written to $output_dir Do you want to continue? (y/n): " answer

# Convert the input to lowercase to handle case-insensitivity
answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')

# Check if the input is "y" or "yes"
if [[ "$answer" == "y" || "$answer" == "yes" ]]; then
    echo "Continuing with execution..."
else
    echo "Exiting..."
    exit 1
fi

# Directory used to store the log, created in the home dir safe to delete after you're finished running the script.


total=$(awk '{ sum += $3 } END { print sum }' "$logd")
echo $total


#determine what software arch / OS this script is being run on
# used to give more helpful and human friendly info.
read kern arch <<< $(uname -sm | awk '{print $1, $2}')

#distribution and OS specific saftey checks
#if we are running on linux, it is prudent to know which distrubution
if [ $kern = "Linux" ]; then
    if [ -f /etc/os-release ]; then
        # For modern Linux distributions
        . /etc/os-release
        echo "Operating System: ${NAME} (${VERSION})"
    elif [ -f /etc/lsb-release ]; then
        # For distributions using lsb-release
        . /etc/lsb-release
        echo "Operating System: ${DISTRIB_ID} (${DISTRIB_RELEASE})"
    elif [ -f /etc/debian_version ]; then
        # For Debian-based systems
        echo "Operating System: Debian ($(cat /etc/debian_version))"
        hlpmsg="\033[32;1mDebian:\033[0m	\033[37;1mapt search ffmpeg | apt install ffmpeg\033[0m"
    elif [ -f /etc/redhat-release ]; then
        # For Red Hat-based systems
        echo "Operating System: $(cat /etc/redhat-release)"
    elif [ "$(uname)" = "Darwin" ]; then
        # For macOS

        hlpmsg="\033[31;1;4m(on OSX you must download and install homebrew:  https://brew.sh/) to manage packages due to Apple restrictions in most cases\033[0m"
    elif [ "$(uname)" = "Linux" ]; then
        # For other Linux systems
        echo "Operating System: Linux ($(uname -r))"
        hlpmsg="\033[32;1mRedhat:\033[0m    \033[37;1pacman search ffmpeg | pacman install ffmpeg\033[0m\n    \033[32;1mDebian:\033[0m	\033[37;1mapt search ffmpeg | apt install ffmpeg\033[0m"
    else
        warn_prompt="Warning: unable to determine platform, procede without platform specific safety checks? y/n"
        read -r -p "$prompt" input
        input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
        if [ "$input" != "y" ]; then
        echo "Exiting..."
        exit 1
    	  fi

    fi
fi

#now that we're done determining what we are running on, we check if ffmpeg/ffprobe are installed on the machine.
if ! command -v ffmpeg &> /dev/null; then
 echo "FFmpeg is not installed on your machine. Please see your distribution's native package manager for instructions on installing ffmpeg."
 echo $hlpmsg

 exit 1
fi
for input_file in "$input_dir"/*; do

    # Skip if it's not a file
    [ -f "$input_file" ] || continue
    echo $(trackFile "$input_file")
    #track the file, skip if it has been compressed before
    if trackFile "$input_file"; then
      echo " "
      echo "already processed"
      echo " "
      continue

    fi

    # Get the base name and extension of the file before we preform any heavy operations
    base_name=$(basename "$input_file")
    extension="${base_name##*.}"
    file_name="${base_name%.*}"

    # Check to make sure the file is actually a video file before we move it, and process it
    if [[ ! " ${video_extensions[@]} " =~ " ${extension} " ]]; then
        # Skip files that end in non video extensions. FFmpeg will automatically error if for example, a text file is renamed to "text.mp4". Because there will be no valid codec data
        continue
    fi

    # Determine the original size of the file (used for compression effectivity benchmarking)
    sizea=$(du -sh "$input_file" | awk '{print $1}')

    # Extract the encoder name using ffprobe

    read encoder width height <<< $(ffprobe -v error -loglevel quiet -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0:nokey=1 "$input_file" | awk -F',' '{print $1, $2, $3}')


    # If the input video is below/above the minimum/maximum required size for the hevc container, set the video filter to resize it to the ceiling/floor
    if [[ "$width" -lt 48 && ! "$height" -lt 32 && ! "$height" -ge 2304  || "$width" -ge 4096  ]]; then
       resize="scale=48:$height"

    elif [[ "$width" -gt 4096 && ! "$height"  -lt 32 && ! "$height" -ge 2304 || "$width" -lt 48 ]]; then
       resize="scale=4096:$height"

    elif [[ "$height" -lt 32 && ! "$width"  -lt 48 && ! "$width"  -ge 4096 || "$height" -gt 2304 ]]; then
       resize="scale=$width:32"

    elif [[ "$height" -gt 2304 && ! "$width"  -lt 48 && ! "$width"  -ge 4096 || "$height" -lt 32 ]]; then
       resize="scale=$width:2034"
    else
       resize="null"
    fi


    if [ ! "$encoder" ]; then
        echo "Invalid video header data found. Skipping..."s
        continue
    fi
    #remember basic info about the video file in order to select the best ffmpeg options, and track size reduction


    echo ""\"$input_file"\" $encoder $sizea" >> $logd




# Skip to the next video if the encoder is already av1
    if [ "$encoder" = "av1" ]; then
        echo "Skipping" "\"$input_file"\"  "Reason:	codec is already av1" >> $logd
        continue
    fi
    echo -e "encoder: \033[31;1;4m$encoder\033[0m"

    # Initialize the encoder variable
    decoder=""
    new_encoder="nan"
    # Map the encoder to the encoder
	case "$encoder" in
	    h264_nvenc)
		  decoder="h264_cuvid"
		  new_encoder="h264"
		  ;;
	    vp9)

		  decoder="libvpx-vp9"

		  ;;
	    # Add more mappings as needed
	    av1)
		  echo "\"$input_file"\" is already encoded with av1, skipping
		  break
		  ;;
	    hevc)
		  decoder="hevc_cuvid"

		  ;;
	    h264)
		  decoder="h264_cuvid"

		  ;;
	    vp8)
		  decoder="vp8_nvenc"

		  ;;
	    *)
		    echo "Unknown encoder: $decoder"

		  ;;

	esac

    # Define the output file path
    output_file="$output_dir/${file_name}.mp4"

    # Ensure the output file does not exist, append a suffix if necessary
    suffix=1
    while [ -e "$output_file" ]; do
        output_file="$output_dir/${file_name}.mp4"
        suffix=$((suffix + 1))
    done

    # Run the ffmpeg command
    if [[ "$encoder" =~ ^vp[0-9]+ ]]; then
      ffmpeg -hwaccel cuda -i "$input_file" -vf "$resize" -c:v hevc_nvenc -cq 26 -qp 26 -preset slow -tag:v "hev1" "$output_file"
    else

      ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i "$input_file" -vf "$resize" -c:v hevc_nvenc -cq 26 -qp 26 -preset slow -tag:v "hev1" "$output_file"
        #ffmpeg -hwaccel cuda   -i "$input_file" -c:v librav1e -rav1e-params speed=7:low_latency=true:bitrate=500 -qp 54 -tile-rows 32 -c:a libopus -b:a 24k "$output_file"
    fi

    # ffmpeg -i $input_file" -c:v libvpx-vp9 -b:v 0 -crf 35  "$output_file"

    #echo "Processed '$input_file' to '$output_file'"

    # ffmpeg -i "$input_file" -c:v librav1e -b:v 2000k -rav1e-params-- first-pass:low_latency=true:bitrate=2000k:tile_rows=32:tile_columns=32:transfer -an -f nut /dev/null

    # ffmpeg -i "$input_file" -c:v librav1e -c:a libopus -rav1e-params--second-pass:bitrate=100k: "$output_file"

    #
    #mv "$output_file" "$input_file"
    #rm "$input_file"
    echo "hashing file changes ..."
    file_hash=$(md5sum "$output_file" | awk '{print $1}')
    echo "$file_hash" >> $cache_file
done

# in the scenario that nothing was changed, and all of the files in a directory were already compressed
# there will be nothing in the new tmpdir, and we'll error out trying to stat things inside of it. Check if the directory has anything inside of it
if [[ -n "$(ls -A "$output_dir")" ]]; then
    # clac how much storage space we've saved by adding the disk usage from all new the files in the tmpdir
    # important to do this before we mv, or rm
    newsize=$(du -sh "$output_dir" | awk '{print $1}')

    # put everything back where it's supposed to be
    mv  $output_dir/* "$input_dir"

else
    # no changes
    newsize=$original_size
    echo -e "\033[32;1mAll videos are already compressed!\033[0m"
fi


# cleanup the temp dir with the converted video files, trap it in the event that the script exits unexpectedly
trap `rm -rf "$output_dir"` EXIT

# print fin. and compression info

echo "finished...: "

echo -e "\033[37;1mOriginal Size:\033[0m \033[32;1m$original_size\033[0m "
echo -e "\033[37;1mNew Size:\033[0m \033[32;1m$newsize\033[0m"
