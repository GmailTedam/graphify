def add(a: int, b: int) -> int:
    return a + b


def total(values: list[int]) -> int:
    result = 0
    for value in values:
        result = add(result, value)
    return result
