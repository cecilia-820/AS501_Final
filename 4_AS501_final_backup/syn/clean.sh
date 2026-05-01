#!/bin/bash
################################################################################
## AS501/AS603
## Final project
## Clean Script
##################################################################################
## Copyright (c) 2025 by Smart Energy-Efficient Design Lab. (SEED), KAIST       ##
## All rights reserved.                                                         ##
##                                                                              ##
##                            Written by Seokhyun Jung    (jsh8186@kaist.ac.kr) ##
##                                       Minyoung Choi    (myconejo@kaist.ac.kr)##
##                                       JeongSeop Park   (eddie020@kaist.ac.kr)##
##                            Supervised by Wanyeong Jung (wanyeong@kaist.ac.kr)##
##################################################################################

################################################################################
## Don't touch
##
    FILES=$(ls -A)

    for FILE in $FILES; do
        if [[ "$FILE" != "clean.sh" && "$FILE" != "run_dc.sh" \
            && "$FILE" != "memory" && "$FILE" != "script" ]]; then
            rm -rf "$FILE"
        fi
    done
##
################################################################################
