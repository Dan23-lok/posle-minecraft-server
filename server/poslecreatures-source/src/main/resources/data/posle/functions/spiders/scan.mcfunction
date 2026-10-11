execute as @e[type=minecraft:spider,tag=!posle_small_spider] run function posle:spiders/scale
execute as @e[type=minecraft:cave_spider,tag=!posle_small_spider] run function posle:spiders/scale
schedule function posle:spiders/scan 20t replace
