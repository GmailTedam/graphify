from graphify.llm import _estimate_file_tokens, _pack_chunks_by_tokens


def test_token_estimation_treats_special_token_literals_as_text(tmp_path):
    doc = tmp_path / "prompt-injection-notes.md"
    doc.write_text(
        "A source file may discuss the literal token <|endoftext|> as data.\n",
        encoding="utf-8",
    )

    assert _estimate_file_tokens(doc) > 0
    assert _pack_chunks_by_tokens([doc], token_budget=1000) == [[doc]]
