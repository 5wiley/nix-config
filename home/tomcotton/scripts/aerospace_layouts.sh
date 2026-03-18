#!/bin/bash

# main command line arg
view=$1

OpenAndMove()
{
        open -a "$1"
        sleep 0.2
        aerospace move-node-to-workspace $2
}

if [ "$view" == "desktop" ]; then
        ws=6
        OpenAndMove "mail" $ws
        OpenAndMove "messages" $ws
        aerospace workspace $ws
        aerospace layout h_tiles

        ws=7
        OpenAndMove "spotify" $ws
        OpenAndMove "discord" $ws

        ws=8
        OpenAndMove "ghostty" $ws
        OpenAndMove "finder" $ws
        aerospace workspace $ws
        aerospace layout v_tiles

        ws=9
        # source ~/.zshrc
        OpenAndMove "zen" $ws
        OpenAndMove "obsidian" $ws
        aerospace workspace $ws
        aerospace layout v_tiles
fi

if [ "$view" == "tutorial" ]; then
	ws=1
	open -a Firefox
	aerospace move-node-to-workspace $ws

	open -a IINA
	sleep 1
	aerospace layout tiling
	aerospace move-node-to-workspace $ws

	open -a WezTerm
	aerospace move-node-to-workspace $ws

	aerospace workspace $ws
	aerospace layout tiling
	for i in {1..3}; do
		aerospace move left
	done
fi
