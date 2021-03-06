module Weapon exposing (Weapon, damage, describe, averageDamage, threatRange, destroyWalls, dagger, sword, axe, whip, pick, enchant)

import Util
import Point exposing (Point)
import Direction exposing (Direction)

import String

type Weapon = Sword
            | Axe
            | Dagger
            | Whip
            | Pick
            | Enchanted Int Weapon

axe : Weapon
axe =
  Axe

dagger : Weapon
dagger =
  Dagger

sword : Weapon
sword =
  Sword

whip : Weapon
whip =
  Whip

pick : Weapon
pick =
  Pick

enchant : Weapon -> Weapon
enchant weapon =
  case weapon of
    Enchanted n weapon' ->
      Enchanted (n+1) weapon'

    _ ->
      Enchanted 1 weapon

destroyWalls : Weapon -> Bool
destroyWalls weapon =
  case weapon of
    Pick -> True
    _ -> False

threatRange : Point -> Direction -> Weapon -> List Point
threatRange pt dir weapon =
  case weapon of
    Axe ->
      Direction.directions
      |> List.map (\dir -> pt |> Point.slide dir)

    Enchanted n weapon' ->
      threatRange pt dir weapon'

    Whip ->
      [ pt |> Point.slide dir
      , pt |> Point.slide dir |> Point.slide dir
      , pt |> Point.slide dir |> Point.slide dir |> Point.slide dir
      ]

    _ ->
      [ pt |> Point.slide dir ]

averageDamage : Weapon -> Int
averageDamage weapon =
  let
    dmgRange =
      (damageRange weapon)

    midpoint =
      (List.length dmgRange) // 2

    avg =
      Util.getAt dmgRange midpoint
      |> Maybe.withDefault 1
  in
    avg

describe : Weapon -> String
describe weapon =
  (case weapon of
    Sword ->
      "sword"

    Axe ->
      "axe"

    Dagger ->
      "dagger"

    Whip ->
      "whip"

    Pick ->
      "pick"

    Enchanted n weapon' ->
      "+" ++ (toString n) ++ " " ++ (describe weapon'))

damage : Int -> Int -> Weapon -> Int
damage m n weapon =
  let range = (damageRange weapon) in
  Util.sample n m 0 range

damageRange weapon =
  case weapon of
    Sword ->
      [2..8]

    Dagger ->
      [1..4]

    Axe ->
      [3..5]

    Whip ->
      [1..6]

    Pick ->
      [0..1]

    Enchanted n weapon' ->
      (damageRange weapon')
      |> List.map (\x -> x + n)
