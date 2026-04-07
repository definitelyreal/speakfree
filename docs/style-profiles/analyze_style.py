#!/usr/bin/env python3
"""Analyze Michael's writing style across platforms."""

import json
import re
from collections import Counter

# Raw message data from each platform
SIGNAL_MESSAGES = [
    "whats the sound",
    "wow, yeah, that happens to me too",
    "Well how's it now?",
    "https://docs.google.com/document/d/13u0LANWT8ZLG5oWuZUrjGU_KdZPKjocaNtRpAksEAwI/edit?tab=t.0",
    "https://bit.ly/about-rg",
    "This is a bit more about our film: https://realitygames.movie/premiere/",
    "I'd love to talk. Can I email you to set up a call? Will loop in our production manager",
    "Hey Soji, it's great to meet you!",
    "I mean who doesnt",
    "I meant these two, are these both desks?",
    "Oh yeah..hm what do you think about bathroom storage?",
    "> First, here's a link to a slide presentation I made for the room a few years ago before the floor project started. https://docs.google.com/presentation/d/1IEDdq6fzA1tKe2zlWrKCXCBBraY8Rv8Uht3C4YbdqvM/edit?usp=drivesdk\n\nAw, this is lovely!\nI would definitely take some of those lamps, the standing one, and the tables, probably not the chair.\n\nWould definitely love to take the dresser if that's an option. So is that white table and that wooden one that folds over, are those both desks?",
    "Hey, would you mind taking a photo of that Desk were mentioning? And what was the other furniture you said that you have?",
    "> OK I was asking claude for some creative writing critique and it's pulling out some serious self help material\n\nHahahaha this reminds me of when I asked it to fix a bug with downloading my company  transcripts and \"make suggestions\" and it responded with an entire plan for turning my company around (that was very bad lol)",
    "Okay new theory…Trump is a mule sent by the future to prevent the United States from developing AGI",
    "Let's phone soon",
    "> Shared with somebody!\n\nThank you!",
    "Man, I've been looking at some manipulation techniques and it's a fucking bummer",
    "Bring your mom!",
    "> Argh, do I skip mother's Day in New York....\n\nHehe",
    "Oh wait I think it's because he doesn't check signal, because he never responds to me",
    "I'm happy to but I know we don't talk much over text",
    "Do you really think Pedro would want to talk to me?",
    "I wonder what's in it",
    "Thanks for letting me know!",
    "Oh wow, haha",
    "How are you doing?",
    "I was thinking about trying to come to sauna club in the morning but I don't think it's in the cards",
    "Working nonstop and moving over the next few days and going to LA on Tuesday :/",
    "Tub sounds nice one of these days, don't think I can for the next week or so",
    "Hi!",
    "If anyone needs cheaper tix though let me know, we don't want price to be an obstacle to people celebrating with us",
    "It'd be awesome to see you all there. You can use code AUSTIN-FRIEND for cheaper tickets, and if you message our main character it's 40% off :)",
    "> Join me at the premier of Michael's movie in May! \n> https://www.realitygames.movie/premiere?code=%7B%7Binvite-code%7D%7D\n\nWhooo!",
    "Haha, surviving",
    "Hi!",
    "Each good for 2!",
    "REBECCA1-YANNQV\nREBECCA2-YABCXD\nREBECCA3-7PJFEP\nREBECCA4-FSZHRZ",
    "yayyy hang tight, coupon codes got weird on the back end but will have em shortly!",
    "Yo, want me to have my LLM do a psy-op operation on you?",
    "Miss you buddy",
    "Talking about you with Jordan Rohrlich!",
    "So this is how it started. The regular chatbot voice, and then the late night claude",
    "\"so you know all my cereal opinions\" is so good",
    "hahahaa",
    "oo ima check your convo",
    "I think the hard part is balancing him not trying to talk to you with him being engaging",
    "Yeah...they will",
    "Hehe",
    "Does it make you wanna actually have conversations with him? What do you think would?",
]

IMESSAGE_MESSAGES = [
    "The one in Brett and Alexa's room is the one you got, and yeah that one's definitely too tall. Could you find a place for it or sell it or somehow get rid of it?",
    "I can talk a little bit later",
    "Awesome thanks!",
    "If you haven't gotten it yet I could send you a copy of the movie and the existing sound design",
    'Loved "You were never a pain Michael.  I would tell you if you were.  You are a dreamer and a leader.  Never a pain.  I think the biggest challenge working with you is you could see this entire experience clearly and it\'s hard for people that work in their lane to see everything in your POV and it would be frustrating to communicate your vision with those folks.  "',
    "Thanks, I appreciate it. Yeah, I have high ambitions and I am exacting and I think it's a good thing, I just need budget for it. I think this whole time I wanted to make a $40M movie and just went and sat for less and that was painful and it'll be really nice in retrospect and hopefully next time we'll have the budget. I think we just needed more supervisors, more layers of management, more professionals, more money to buy more time from more experienced people",
    "It's hard dealing with that now as I'm keeping that same quality bar and obsessing over details and watching the premier get closer and yeah at some point you got to pick or it gets picked for you",
    'Loved "I did now! "',
    "Oh really? That would be amazing",
    "OK, yeah I think that would also work. Sounds really exciting!",
    "I'm free now if you want to give me a call but no stress, we can also talk tomorrow. What's your email address?",
    'Loved "It\'s a lot of communication for a gal that sucks at phone lmao 😭  "',
    "hey, what's up stud",
    "Happy Passover!",
    "Hey Mom! I think it was, we finished today",
    "I'm around tomorrow and the next day",
    "Hey dude!",
    "Sorry it's been nuts. I'm in Oakland, well I was but we had to leave our place because of mold",
    "So just moved to Berkeley",
    "But I'm in town, are you around?",
    "What are you up to Sunday? I was gonna go dancing on the beach",
    "Otherwise pretty flexible, my friend is having a Seder tomorrow night if you wanted to join",
    "Hey! Any chance you're back in LA?",
    "Hey! You in town?",
    "OK that sounds great, thanks!",
    "This is yours",
    "It was on my nightstand",
    "Listening to me",
    'Loved "I\'m gonna do my best to make something happen "',
    "Yeah I'm down, I'm also down to ask for a comp",
    "Hehehe",
    "Yeah in 2022!",
    'Loved "I\'m sorry about yesterday didn\'t mean to bring you in the middle of things but it sounds like you guys talked it over and everything\'s good?"',
    "Ah whoops, no worries!",
    "Hey Gill! Connecting you here with Joel our associate producer. Would love to talk premier stuff with you at some point, see if there's something we can do together",
    "On my way!",
    "Hey, whatcha wanna do?",
    "I'm in beverly hills, we could go somewhere near here",
    "Or am flexible, could do weho, whatever",
    "That works yeah, although i dont have a jacket",
    "Can i message you when leaving here? It could end ip beinf a little bit later, but not positive",
    "Ok! Haha um, medium",
    "So cute!!",
    'Liked "if i don\'t reply, call me. "',
    "Ok heading over! Around 9:38 it says",
    "OK no stress, take your time",
    "Hey Ataseia! I'm in town and was going to come to Ecstatic Dance, and Elizabeth was going to come but is not super flush right now, was wondering if you might be able to do a discount or a comp for one of us?",
    "No worries either way, and see you soon, I'm excited!",
    "Ohh can I put the bebes on my story?",
    'Loved "Definitely!"',
]

SLACK_MESSAGES = [
    "Head rigging I will look at!\n\nHmm, I think you staying on 5030 will make the most sense. I was going to try and get you notes today — is there anything else that'd help you move forward?",
    "Okay amazing",
    "Would love to ask your thoughts on look for Sean — have a second to chat?",
    "For ref, my earlier ref, his last version, and his latest version",
    "Hey hey, do you mind if we push 15min?",
    "Just jumped on",
    "Hey hey, was aiming to get you notes today but it might take a bit longer — could we do a call a bit later than our usual one with notes?",
    "Sure!",
    "Shall we skip today at least until I can review then?",
    "Sounds good",
    "Awesome! Finishing a few things and then will dive in!",
    "Hey hey, notes are up! I'm jumping in the car for a long drive, would you like to chat in about 20?",
    "Alright, I'm on the zoom link!",
    "Hey, are you good to push till I finish notes? Hoping will be by 2p but want to be sure I'm thorough",
    "I don't...think so? But might be safer to do that if it's easy for you to",
    "Either way — sooner is better since they'll want to close it out but that's not a rush. But if that's a good thing to do for an hour seems like a good use of time",
    "Alright! Am ready to chat whenever you are :slightly_smiling_face:",
    "Oh wait finsihing one note",
    "Alright, jumping on!",
    "Remote into computer\nSplashtop\nUsername: mikeyla@gmail.com\nPassword: RealityGames1234!\n\nIt also has tailscale set up on it",
    "Hey sure, that works for me,. Awesome! Excited to see it!",
    "Yep that works!",
    "Let's do it",
    "Sorry, was also in the flow :slightly_smiling_face:",
    "Hey, do you mind if we push our meeting a little bit? Not sure if I need to but am focused on getting a package out to sound design and then can get everything out to you!",
    "Thank you!",
    "Want to do a huddle in a min? Just about to walk out of the office",
    "Hey hey, should I still wait for a new draft to make notes?",
    "Awesome!",
    "Awesome! I'll review and ping you when done and we can jump on a call?",
    "When do you have to leave for the appt? Yeah let's meet beforehand either way even if it's not the whole thing. Just about to dive into it",
    "Okay, notes up for the first section!",
    "Wanna do a quick chat? There's 4 video refs to watch",
    "Yep!",
    "On the link",
    "Oh hell yes, that sounds great and I'm looking forward to it! Have a good weekend Bradley",
    "Awesome, just got out of a meeting, excited to dive in and look!",
    "Okay awesome!\nDo you mind if we start at :20 after?",
    "Shoot, need a bit longer. I can message you when ready?",
    "Thank you!",
    "Alright, notes up! Sorry about that, jumping on the zoom now!",
    "Hey hey, do you want to meet today? Or meet later in the day if you're jamming on things?",
    "Making notes on it now!",
    "Okay sounds good!",
    "Yeah lemme make the notes and we can jump on if you want to?",
    "Alright, notes up! Let me know if you're like to jump on a call",
    "Shoot had do not disturb, jumping on",
    "Hi! Big news...after seven years in the making, we are looking at doing a big red carpet PREMIERE OF REALITY GAMES in San Francisco, followed by one in LA!\n\nWe're looking at a few dates, and would really like to do it when you're able to make it. Would you be able to fill out this quick form by Friday to let us know when you're available?\n\nCurrently looking at May 15, May 8, June 5, June 19 (with July 11 and 18 as alternates.)\n\nGet excited!!",
    "Awesome, just got out of a meeting, excited to dive in and look!",
    "Hey hey, do you want to meet today? Or meet later in the day if you're jamming on things?",
]

# Gmail snippets - strip signatures and HTML entities
GMAIL_RAW = [
    "Can we get this done on Monday? Please let me know what I need to do. If there's another form, another hoop, another hiccup, can you collect it and we can either speak on the phone or resolve it",
    "Hello, That address is the same, yes. It's listed as business because it's a virtual mailbox, but it's the address on all my credit card statements, bank accounts, and everything else. I",
    "Hi Wolfie, My sincere apologies on getting this to you so late! Here's our loop group sheet! Please let us know if you have any questions, and I'm excited for the session! Thanks very much,",
    "Each model gets a sandboxed computer, and a repetitive prompt: I want you to improve yourself.",
    "Organize room Go to Erica's Bike and downstairs Loop group Date me doc launch VFX Finances Talk to Pez Other housing Eat well Work out",
    "Is it 10-15 minutes or 8? Which voice? Voice options Get gender and When I say \"yeah, I think that's it\" there's a pause. Can deposits vary based on what the conversation context is?",
    "Also add Betta testing notice to the top",
    "Add feedback prompt Add this signal that message you with the list of people, and your custom dare me doc page Get a domain name Signal ask if you have any feedback. It lets you go back to the LLM",
    "You came towards me. You asked for more. You showed interest and then pulled back. You said you wanted to come to Room Service, then you said no. I know you say \"respect my boundaries\" but",
    "You going through a hard time doesn't give you a pass on how your actions affect other people. Even when I'm supporting you, I'm still a person with feelings. And at that point when we had",
    "This constructive, that was my time to be supported. My need was important then and yours wasn't. When we had made plans together, you backed out without really communicating with me for a week,",
    "Hi all, I've been trying to get in touch with y'all for months now about my account. When I spoke with Nunzio many months ago, he said he'd open it and get me access. I really need to",
    "I hear you that you felt like I brought that up at a vulnerable time. And also… you reached out to a gay man, told him you loved him, connected deeply, told him he was beautiful, and then…when he told",
    "It feels like I stopped mattering to you, when I used to matter a lot And the way you said it felt to me like a big fuck you Care about you a lot Think you're an extraordinary person And this is",
    "Hi Karol, Just tried you, feel free to give me a call if you'd like to touch base, 310-595-5330. I think we can make it work if you think you'd be able to send us something by the end of Monday",
    "Sure, Joel will send over a contract ASAP. Monday I think would be tricky, since we need to get started. Would you be able to do it by Sunday?",
    "Hi Karol, Of course re rate. I wish we had a larger budget and I was able to pay your full rate. Yes, the spec assignment is the only thing you really need to look at. The rest I'm sending just as",
    "Sure, if Joel sent the spec assignment, that's everything that you need. This Coda database has all our notes — if you go into notes and filter by Quick List, you can see our notes on our editorial",
    "Yes, that sounds great. Thank you Karol! Best,",
    "I'd say abstractly incorrect. It was more that the grammar felt wrong, both generally for video games and in the context of what the film was doing. We've definitely auditioned them at",
    "Hi all, It was great speaking with you earlier today, and thanks very much for taking the time. Once you have a sense of what path makes sense to you, I'd be happy to speak further and see if there",
    "Hi Karol, Sure, will try to answer your questions as best as I can. So, the full story is that we're working with Melodygun to do sound on this project and hired them as a package including sound",
    "Hello, Sorry about that, I'd love to talk about it and get my site back! How do I do that?",
    "Hi Stephen and Maggie, Thanks for all that information, that's very helpful. I think it would be great to walk through some different examples of videos with different types of updates needed. A",
    "That works, I'll call you at 2!",
    "That makes a lot of sense. I've been looking through some of your Skilljar courses and there's a ton of content. I can see how keeping that current with the pace of product changes would be a",
    "Hey Allen! Just tried again. Is there a good time for you today or tomorrow?",
    "Hi Jessie, Michael the Director here. Thanks so much for getting back to us so quickly! To answer your questions: - We are working with a sound house, Melodygun, who is doing the foley, re-recording,",
    "Hi Karol, Alex Burke is our film's composer and had incredible things to say about you. (I'm also copying Joel, our Production Manager here.) We're looking for a Video Game Sound Designer",
    "Hi Tom, I hope all is well with you. I'm reaching out because out current sound designer looks like he's going to need some help to hit our deadline, so we're looking to bring someone else",
    "Hi Chris, I hope all is well with you. I'm reaching out because out current sound designer looks like he's going to need some help to hit our deadline, so we're looking to bring someone",
    "Amazing, thank you!",
]


def clean_message(msg):
    """Strip quoted replies, URLs, and reaction messages for analysis."""
    # Remove quoted reply lines
    lines = msg.split('\n')
    cleaned_lines = [l for l in lines if not l.startswith('>')]
    msg = '\n'.join(cleaned_lines).strip()

    # Skip if it's a reaction (Loved/Liked "...")
    if re.match(r'^(Loved|Liked|Emphasized|Laughed at|Disliked|Questioned) "', msg):
        return None

    # Skip if it's just a URL
    if re.match(r'^https?://\S+$', msg):
        return None

    # Skip if it's just coupon codes or credentials
    if re.match(r'^[A-Z0-9]{6,}', msg) and '\n' in msg:
        return None

    # Remove inline URLs for text analysis
    msg = re.sub(r'https?://\S+', '', msg).strip()

    # Remove email signatures
    msg = re.sub(r'Michael Morgenstern \(he/him\).*$', '', msg, flags=re.DOTALL).strip()
    msg = re.sub(r'This email is \*?Definitely Real.*$', '', msg, flags=re.DOTALL).strip()

    # HTML entities
    msg = msg.replace('&#39;', "'").replace('&amp;', '&').replace('&quot;', '"').replace('&lt;', '<').replace('&gt;', '>')

    if not msg or len(msg) < 2:
        return None
    return msg


def analyze_platform(name, messages):
    """Analyze writing patterns for a platform."""
    # Clean messages
    cleaned = [clean_message(m) for m in messages]
    cleaned = [m for m in cleaned if m is not None]

    if not cleaned:
        return None

    n = len(cleaned)

    # --- Capitalization ---
    starts_cap = sum(1 for m in cleaned if m[0].isupper()) / n
    starts_lower = sum(1 for m in cleaned if m[0].islower()) / n

    # --- Punctuation at end ---
    ends_period = sum(1 for m in cleaned if m.rstrip()[-1] == '.') / n
    ends_question = sum(1 for m in cleaned if m.rstrip()[-1] == '?') / n
    ends_exclamation = sum(1 for m in cleaned if m.rstrip()[-1] == '!') / n
    ends_no_punct = sum(1 for m in cleaned if m.rstrip()[-1].isalnum()) / n
    ends_ellipsis = sum(1 for m in cleaned if m.rstrip().endswith('...') or m.rstrip().endswith('..')) / n
    ends_emoji = sum(1 for m in cleaned if not m.rstrip()[-1].isascii()) / n

    # --- Message length ---
    word_counts = [len(m.split()) for m in cleaned]
    avg_words = sum(word_counts) / n
    median_words = sorted(word_counts)[n // 2]

    # --- Contractions ---
    contraction_patterns = [
        r"\b(i'm|i've|i'll|i'd|don't|doesn't|didn't|won't|wouldn't|couldn't|shouldn't|can't|wasn't|weren't|isn't|aren't|hasn't|haven't|it's|that's|what's|there's|here's|who's|let's|he's|she's|we're|they're|you're|you've|you'll|you'd|we've|we'll|we'd|they've|they'll|they'd|ain't|gonna|wanna|gotta)\b"
    ]
    msgs_with_contractions = 0
    total_contractions = 0
    for m in cleaned:
        found = re.findall(contraction_patterns[0], m.lower())
        if found:
            msgs_with_contractions += 1
            total_contractions += len(found)
    contraction_rate = msgs_with_contractions / n

    # --- Emoji ---
    emoji_pattern = re.compile(
        "["
        "\U0001F600-\U0001F64F"  # emoticons
        "\U0001F300-\U0001F5FF"  # symbols & pictographs
        "\U0001F680-\U0001F6FF"  # transport & map
        "\U0001F1E0-\U0001F1FF"  # flags
        "\U00002702-\U000027B0"
        "\U000024C2-\U0001F251"
        "\U0001f926-\U0001f937"
        "\U00010000-\U0010ffff"
        "\u2640-\u2642"
        "\u2600-\u2B55"
        "\u200d"
        "\u23cf"
        "\u23e9"
        "\u231a"
        "\ufe0f"
        "]+", flags=re.UNICODE
    )
    # Also count text emoticons
    text_emoticons = re.compile(r'(?::\)|:\(|:D|:P|;\)|:\/|:\||<3|xD|XD|>_<|:o|:O|\^\^|;P|:3)')

    msgs_with_emoji = 0
    all_emojis = []
    for m in cleaned:
        unicode_emojis = emoji_pattern.findall(m)
        text_emos = text_emoticons.findall(m)
        if unicode_emojis or text_emos:
            msgs_with_emoji += 1
            all_emojis.extend(unicode_emojis)
            all_emojis.extend(text_emos)
    emoji_rate = msgs_with_emoji / n
    top_emojis = [e for e, _ in Counter(all_emojis).most_common(5)]

    # --- Shortcuts/slang ---
    shortcut_patterns = {
        'haha': r'\bhaha+\b',
        'hehe': r'\bhehe+\b',
        'lol': r'\blol\b',
        'lmao': r'\blmao\b',
        'tbh': r'\btbh\b',
        'idk': r'\bidk\b',
        'imo': r'\bimo\b',
        'omg': r'\bomg\b',
        'ngl': r'\bngl\b',
        'rn': r'\brn\b',
        'gonna': r'\bgonna\b',
        'wanna': r'\bwanna\b',
        'gotta': r'\bgotta\b',
        'ima': r'\bima\b',
        'lemme': r'\blemme\b',
        'em': r'\bem\b',
        'whatcha': r'\bwhatcha\b',
        'yayyy': r'\byay+\b',
        'whooo': r'\bwhoo+\b',
        'oo': r'\boo+\b',
        'hm': r'\bhm+\b',
        'um': r'\bum+\b',
        'ah': r'\bah+\b',
        'oh': r'\boh\b',
        'nah': r'\bnah\b',
    }
    found_shortcuts = {}
    for name_s, pat in shortcut_patterns.items():
        count = sum(1 for m in cleaned if re.search(pat, m.lower()))
        if count > 0:
            found_shortcuts[name_s] = count

    # --- Fragments vs full sentences ---
    fragments = 0
    for m in cleaned:
        # A fragment: short (< 8 words), no verb or no subject-verb structure
        words = m.split()
        if len(words) <= 5:
            fragments += 1
        elif not re.search(r'\b(is|are|am|was|were|have|has|had|do|does|did|will|would|could|should|can|may|might|shall)\b', m.lower()) and len(words) <= 8:
            fragments += 1
    fragment_rate = fragments / n

    # --- Greeting patterns ---
    greetings = Counter()
    for m in cleaned:
        first_word = m.split()[0].lower().rstrip(',!') if m.split() else ''
        if first_word in ['hey', 'hi', 'hello', 'yo', 'sup', 'heya', 'hiya', 'howdy']:
            greetings[first_word] += 1

    # --- Signoff patterns ---
    signoffs = Counter()
    for m in cleaned:
        last_words = m.lower().rstrip('!.,').split()[-2:] if len(m.split()) > 1 else []
        last_phrase = ' '.join(last_words)
        if any(s in last_phrase for s in ['thanks', 'thank you', 'cheers', 'best', 'talk soon', 'see you', 'take care']):
            for s in ['thanks', 'thank you', 'cheers', 'best', 'talk soon', 'see you', 'take care']:
                if s in last_phrase:
                    signoffs[s] += 1

    # --- Filler/hedge words ---
    hedge_words = {
        'I think': r'\bi think\b',
        'I mean': r'\bi mean\b',
        'kind of': r'\bkind of\b',
        'sort of': r'\bsort of\b',
        'pretty': r'\bpretty\b',
        'definitely': r'\bdefinitely\b',
        'honestly': r'\bhonestly\b',
        'basically': r'\bbasically\b',
        'actually': r'\bactually\b',
        'just': r'\bjust\b',
    }
    found_hedges = {}
    for hw, pat in hedge_words.items():
        count = sum(1 for m in cleaned if re.search(pat, m.lower()))
        if count > 0:
            found_hedges[hw] = count

    # --- Lowercase "i" ---
    lowercase_i = sum(1 for m in cleaned if re.search(r'\bi\b', m) and not re.search(r'\bI\b', m))
    mixed_i = sum(1 for m in cleaned if re.search(r'\bi\b', m) and re.search(r'\bI\b', m))
    uppercase_i = sum(1 for m in cleaned if re.search(r'\bI\b', m) and not re.search(r'(?<![A-Z])\bi\b(?![A-Z])', m))
    msgs_with_i = sum(1 for m in cleaned if re.search(r'\b[iI]\b', m))

    # --- Multi-message tendency (newlines within a message) ---
    multi_line = sum(1 for m in cleaned if '\n' in m) / n

    # --- Run-on / comma splice tendency ---
    comma_and = sum(1 for m in cleaned if ', and ' in m.lower() or ', but ' in m.lower()) / n

    # --- Em dash usage ---
    em_dash = sum(1 for m in cleaned if '—' in m or ' - ' in m) / n

    # --- Ellipsis usage ---
    ellipsis = sum(1 for m in cleaned if '...' in m or '..' in m) / n

    # --- Typo/casual spelling rate ---
    typos = []
    typo_msgs = 0
    for m in cleaned:
        if re.search(r'\b(finsihing|beinf|ip|htat|whatcha|em)\b', m.lower()):
            typo_msgs += 1

    # Build profile
    profile = {
        "platform": name,
        "samples_raw": len(messages),
        "samples_analyzed": n,
        "capitalization": {
            "starts_capitalized": round(starts_cap, 2),
            "starts_lowercase": round(starts_lower, 2),
        },
        "ending_punctuation": {
            "period": round(ends_period, 2),
            "question_mark": round(ends_question, 2),
            "exclamation": round(ends_exclamation, 2),
            "no_punctuation": round(ends_no_punct, 2),
            "ellipsis": round(ends_ellipsis, 2),
            "emoji": round(ends_emoji, 2),
        },
        "message_length": {
            "avg_words": round(avg_words, 1),
            "median_words": median_words,
            "distribution": {
                "1-3_words": round(sum(1 for w in word_counts if 1 <= w <= 3) / n, 2),
                "4-10_words": round(sum(1 for w in word_counts if 4 <= w <= 10) / n, 2),
                "11-25_words": round(sum(1 for w in word_counts if 11 <= w <= 25) / n, 2),
                "26+_words": round(sum(1 for w in word_counts if w >= 26) / n, 2),
            }
        },
        "contraction_rate": round(contraction_rate, 2),
        "avg_contractions_per_msg": round(total_contractions / n, 2),
        "emoji": {
            "rate": round(emoji_rate, 2),
            "top_emojis": top_emojis,
        },
        "shortcuts_and_slang": {k: v for k, v in sorted(found_shortcuts.items(), key=lambda x: -x[1])},
        "fragment_rate": round(fragment_rate, 2),
        "hedge_words": {k: v for k, v in sorted(found_hedges.items(), key=lambda x: -x[1])},
        "greetings": dict(greetings.most_common()),
        "signoffs": dict(signoffs.most_common()),
        "structural": {
            "multi_line_messages": round(multi_line, 2),
            "comma_splices": round(comma_and, 2),
            "em_dash_usage": round(em_dash, 2),
            "ellipsis_usage": round(ellipsis, 2),
        },
        "i_capitalization": {
            "always_uppercase_I": uppercase_i,
            "sometimes_lowercase_i": lowercase_i,
            "mixed_in_same_msg": mixed_i,
            "msgs_containing_i": msgs_with_i,
        },
        "sample_messages": cleaned[:10],
    }

    return profile


# Run analysis
platforms = {
    "signal": SIGNAL_MESSAGES,
    "imessage": IMESSAGE_MESSAGES,
    "slack": SLACK_MESSAGES,
    "gmail": GMAIL_RAW,
}

results = {}
for name, msgs in platforms.items():
    profile = analyze_platform(name, msgs)
    if profile:
        results[name] = profile

# Output
print(json.dumps(results, indent=2, ensure_ascii=False))
