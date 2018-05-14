#!/bin/bash

# run in pwd
cd $(dirname $0)

# spit out date for handy logging
date

# heavily based on NoctuaNivalis' minerva-syncer code

temp1="/tmp/temp1"
temp2="/tmp/temp2"

# msg cache
msgf=".msg"
url="https://minerva.ugent.be"

# apparently we need 2 cookie files, an in and an out cookie
cin="/tmp/cookie1"
cout="/tmp/cookie2"

# will be set to true if running for the first time later on
first=false

swap_cookies() {
    ctemp="$cin"
    cin="$cout"
    cout="$ctemp"
}

check_empty() {
    # check if field contained something

    if test -z "$1"; then
        echo "field was empty"
        exit 1
    fi
}

if test -e "config.sh"; then
    # not secure, but who cares?
    . "config.sh"

else
    first=true
    echo
    echo "This appears to be the first time you're running this script."
    echo "Before we start, we need a few details"
    echo "What is your UGent username?"
    echo
    read -p "UGent username: " username
    check_empty "$username"
    echo
    echo "As an automatic script, we will need your password. Keep in mind that it will be stored as plain text in config.sh!"
    echo
    stty -echo
    read -p "UGent password: " password; echo
    stty echo
    check_empty "$password"
    echo
    echo "Last thing I need is a discord webhook url, set an up and paste the url below"
    echo
    read -p "Discord webhook: " webhook
    check_empty "$webhook"
    echo
    # setup file structure and auto generated configs

    # only alert new messages
    lastsync=".last"
    date > "$lastsync"

    # All the configs get written
    {
        echo "username=\"$username\""
        echo "password=\"$password\""
        echo "webhook=\"$webhook\""
    } > "config.sh"

fi

touch "$temp1"
touch "$temp2"

# keeps track of handled messages
touch "$msgf"

# Cookie init and authentication salt retrieval
echo -n "Initializing cookies and retrieving salt..."
curl -c "$cout" "${url}/secure/index.php?external=true" --output "$temp1" 2> /dev/null
swap_cookies
salt=$(cat "$temp1" | sed '/authentication_salt/!d' | sed 's/.*value="\([^"]*\)".*/\1/')
echo "done"

# Logging in
echo -n "Logging in as $username..."
curl -b "$cin" -c "$cout" \
    --data "login=$username" \
    --data "password=$password" \
    --data "authentication_salt=$salt" \
    --data "submitAuth=Log in" \
    --location \
    --output "$temp2" \
        "${url}/secure/index.php?external=true" 2> /dev/null
swap_cookies
echo "done"

# retrieve home page to parse
echo -n "Retrieving home page..."
curl -b "$cin" -c "$cout" "${url}/index.php" --output "$temp1" 2> /dev/null
echo "done"

echo -n "Constructing Minerva Courses tree..."
# Parsing $temp1 and retrieving minerva document tree.
cat "$temp1" | sed '/course_home.php?cidReq=/!d' | # filter lines with a course link on it.
    sed 's/.*course_home\.php?cidReq=\([^"]*\)">\([^<]*\)<.*/\2,\1/' | # separate course name and cidReq with a comma.
    sed 's/ /_/g' | # avod trouble by substituting spaces by underscores.
cat - > "$temp2"
echo "done"

# iterate over every course and get new messages
echo -n "Syncing up"
for course in $(cat "$temp2"); do
    echo -n "."
    name=$(echo "$course" | sed 's/,.*//')
    cidReq=$(echo "$course" | sed 's/.*,//')
    link="${url}/main/announcements/announcements.php?cidReq=${cidReq}"

    curl -b "$cin" -c "$cout" "$link" --output "$temp1" 2> /dev/null
    swap_cookies

    data=$(cat "/tmp/temp1" | recode -f html..ascii | sed '1,/<div id="sort_area">/d' |
        sed '/<label id="select_all_none_actions_label"/,$d')

    announcements="$(echo "$data" | 
        sed '/<div id="announcement_/!d' |
        sed 's/^<div id="announcement_\([^"]*\).*/\1/')"

    # collecting messages
    for id in $announcements; do 
        if ! grep -q $id "$msgf"; then
            echo .
            echo "$data" > data
            message="$(printf "%s" "$data" |
                sed -ne "/<div id=\"announcement_${id}\"/,$ p" |
                sed -e "s/announcement_${id}//g" | 
                sed -e '/announcement_[0-9]+/,$d' |
                sed -e 's/<[^>]*>//g')"$'\n\n'
            echo
            echo "$id" >> "$msgf"

            echo "$message"
            
            echo -n '{"username":"Minerva", "content": "' > .to_send
            
            if [ "$size" -gt "1000" ] ; then
                message="${message:0:1000}..."
            fi

            msgurl="${url}/main/announcements/announcements.php?cidReq=${cidReq}"
            
            # escape all quotations, slashes and control characters
            # json is a bitch
            message="$(printf "%q" $"$message
            
            $msgurl" | sed 's/\\ //g' | sed 's/\([^\\]\)"/\1\\"/g' | sed "s/\\\'/'/g" | sed "s/$'//g")"

            size=${#message}


            printf "%s" $"${message%?}" >> .to_send

            echo -n '"}' >> .to_send 
         
            # hurray!
            echo "New message found!"

            cat .to_send

            # don't send if running for the first time
            if [ "$first" = false ] ; then
                if test -e .to_send; then
                    curl -H "Content-Type: application/json; charset=utf-8" \
                        -X POST \
                        -d @.to_send \
                        "$webhook" 
                    sleep 4
                fi
            fi
        fi
    done

done

echo "done"

